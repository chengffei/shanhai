import Foundation
import Compression
import Metal

struct Country: Decodable, Identifiable {
    let id: Int
    let a3: String
    let iso2: String
    let name: String
    let nameEn: String
    let wikidata: String
    let continent: String
    let subregion: String
    let pop: Double
    let label: [Double]
    let labelRank: Int
    let minLabel: Double
    let area: Double
    let outline: [[Int]]
    let bbox: [Double]
}

struct Region: Decodable, Identifiable {
    let id: Int
    let name: String
    let nameEn: String
    let wikidata: String
    let iso: String
    let type: String
    let label: [Double]
    let labelRank: Int
    let area: Double?
    let country: Int
    let pixels: Int
    let outline: [[Int]]
    let bbox: [Double]
}

struct City: Decodable {
    let name: String
    let lon: Double
    let lat: Double
    let minZoom: Double
    let pop: Double
    let cap: Int          // 2 首都 1 省会 0 其他
}

struct Marine: Decodable {
    let name: String
    let lon: Double
    let lat: Double
    let kind: String
    let minLabel: Double
    let rank: Int
    let area: Double
}

/// 离线地理数据：元数据、ID 栅格（CPU 与 GPU 共用一份内存）、边界线、高程。
final class GeoData {
    let countries: [Country]          // 下标 = id - 1
    let regions: [Region]
    let cities: [City]                // 按重要性排好
    let marine: [Marine]              // 海洋、海、湾，按重要性排好
    let idWidth: Int, idHeight: Int
    let idBuffer: MTLBuffer           // 前半 uint16 省 ID，后半 uint8 国家 ID；行优先，(0,0) 在西北角
    let countryOffset: Int
    private let heightBuffer: MTLBuffer
    let regionTexture: MTLTexture
    let countryTexture: MTLTexture
    let borderVertices: MTLBuffer     // float2 (lon, lat) 度
    let borderIndices: MTLBuffer      // uint32，0xFFFFFFFF 断开
    let countryLineRange: Range<Int>
    let regionLineRange: Range<Int>
    let heightTexture: MTLTexture     // r16Float，米

    init(device: MTLDevice) throws {
        let dir = Bundle.main.resourceURL!.appendingPathComponent("Geo")
        let dec = JSONDecoder()
        countries = try dec.decode([Country].self, from: Data(contentsOf: dir.appendingPathComponent("countries.json")))
        regions = try dec.decode([Region].self, from: Data(contentsOf: dir.appendingPathComponent("regions.json")))
        cities = try dec.decode([City].self, from: Data(contentsOf: dir.appendingPathComponent("cities.json")))
        marine = try dec.decode([Marine].self, from: Data(contentsOf: dir.appendingPathComponent("marine.json")))

        // ID 栅格：头 8 字节宽高，之后 raw deflate
        let ids = try Data(contentsOf: dir.appendingPathComponent("ids.bin"), options: .alwaysMapped)
        let (w, h) = ids.withUnsafeBytes { ($0.load(fromByteOffset: 0, as: UInt32.self), $0.load(fromByteOffset: 4, as: UInt32.self)) }
        idWidth = Int(w); idHeight = Int(h)
        let n = idWidth * idHeight
        // 直接解压进一块共享显存：前 2n 字节是省 ID，后 n 字节是国家 ID。不经过临时内存，
        // 否则 96 MB 的临时缓冲释放后会被分配器留着不还
        let buf = device.makeBuffer(length: n * 3, options: .storageModeShared)!
        try GeoData.inflate(ids.dropFirst(8), into: buf.contents(), expected: n * 3)
        idBuffer = buf
        countryOffset = n * 2
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: idWidth, height: idHeight, mipmapped: false)
        rd.storageMode = .shared; rd.usage = .shaderRead
        regionTexture = buf.makeTexture(descriptor: rd, offset: 0, bytesPerRow: idWidth * 2)!
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: idWidth, height: idHeight, mipmapped: false)
        cd.storageMode = .shared; cd.usage = .shaderRead
        countryTexture = buf.makeTexture(descriptor: cd, offset: n * 2, bytesPerRow: idWidth)!

        // 边界线
        let b = try Data(contentsOf: dir.appendingPathComponent("borders.bin"), options: .alwaysMapped)
        let hdr = b.withUnsafeBytes { p in (0..<6).map { Int(p.load(fromByteOffset: $0 * 4, as: UInt32.self)) } }
        let nv = hdr[0], ni = hdr[1]
        countryLineRange = hdr[2]..<(hdr[2] + hdr[3])
        regionLineRange = hdr[4]..<(hdr[4] + hdr[5])
        let bv = b.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + 24, length: nv * 8, options: .storageModeShared)! }
        let bi = b.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + 24 + nv * 8, length: ni * 4, options: .storageModeShared)! }
        borderVertices = bv
        borderIndices = bi

        // 高程 → half
        let hd = try Data(contentsOf: dir.appendingPathComponent("height.bin"), options: .alwaysMapped)
        let (hw, hh) = hd.withUnsafeBytes { (Int($0.load(fromByteOffset: 0, as: UInt32.self)), Int($0.load(fromByteOffset: 4, as: UInt32.self))) }
        // 同样直接解压进共享显存，再原地把 Int16 改写成 Float16（同为 2 字节）
        let hbuf = device.makeBuffer(length: hw * hh * 2, options: .storageModeShared)!
        try GeoData.inflate(hd.dropFirst(8), into: hbuf.contents(), expected: hw * hh * 2)
        let src = hbuf.contents().bindMemory(to: Int16.self, capacity: hw * hh)
        let dst = UnsafeMutableRawPointer(src).bindMemory(to: Float16.self, capacity: hw * hh)
        for i in 0..<(hw * hh) { let v = src[i]; dst[i] = Float16(Float(v)) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: hw, height: hh, mipmapped: false)
        td.usage = .shaderRead; td.storageMode = .shared
        heightBuffer = hbuf
        heightTexture = hbuf.makeTexture(descriptor: td, offset: 0, bytesPerRow: hw * 2)!
    }

    func country(_ id: Int) -> Country? { id > 0 && id <= countries.count ? countries[id - 1] : nil }
    func region(_ id: Int) -> Region? { id > 0 && id <= regions.count ? regions[id - 1] : nil }

    /// 经纬度 → (省级 ID, 国家 ID)，0 表示海洋或无。
    func lookup(lat: Double, lon: Double) -> (region: Int, country: Int) {
        var x = Int(((lon + 180) / 360 * Double(idWidth)).rounded(.down)) % idWidth
        if x < 0 { x += idWidth }
        let y = min(idHeight - 1, max(0, Int(((90 - lat) / 180 * Double(idHeight)).rounded(.down))))
        let i = y * idWidth + x
        let r = idBuffer.contents().load(fromByteOffset: i * 2, as: UInt16.self)
        let c = idBuffer.contents().load(fromByteOffset: countryOffset + i, as: UInt8.self)
        return (Int(r), Int(c))
    }

    static func inflate(_ data: Data, into dst: UnsafeMutableRawPointer, expected: Int) throws {
        let written = data.withUnsafeBytes { src in
            compression_decode_buffer(dst.assumingMemoryBound(to: UInt8.self), expected,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expected else { throw NSError(domain: "GeoData", code: 1, userInfo: [NSLocalizedDescriptionKey: "inflate \(written)/\(expected)"]) }
    }
}
