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

/// 离线地理数据：元数据、ID 栅格（CPU 与 GPU 共用一份内存）、边界线、高程。
final class GeoData {
    let countries: [Country]          // 下标 = id - 1
    let regions: [Region]
    let cities: [City]                // 按重要性排好
    let idWidth: Int, idHeight: Int
    let regionIDs: MTLBuffer          // uint16，行优先，(0,0) 在西北角
    let countryIDs: MTLBuffer         // uint8
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

        // ID 栅格：头 8 字节宽高，之后 raw deflate
        let ids = try Data(contentsOf: dir.appendingPathComponent("ids.bin"))
        let (w, h) = ids.withUnsafeBytes { ($0.load(fromByteOffset: 0, as: UInt32.self), $0.load(fromByteOffset: 4, as: UInt32.self)) }
        idWidth = Int(w); idHeight = Int(h)
        let n = idWidth * idHeight
        let raw = try GeoData.inflate(ids.dropFirst(8), expected: n * 3)
        let rb = device.makeBuffer(length: n * 2, options: .storageModeShared)!
        let cb = device.makeBuffer(length: n, options: .storageModeShared)!
        raw.withUnsafeBytes { p in
            memcpy(rb.contents(), p.baseAddress!, n * 2)
            memcpy(cb.contents(), p.baseAddress! + n * 2, n)
        }
        regionIDs = rb
        countryIDs = cb
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: idWidth, height: idHeight, mipmapped: false)
        rd.storageMode = .shared; rd.usage = .shaderRead
        regionTexture = rb.makeTexture(descriptor: rd, offset: 0, bytesPerRow: idWidth * 2)!
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: idWidth, height: idHeight, mipmapped: false)
        cd.storageMode = .shared; cd.usage = .shaderRead
        countryTexture = cb.makeTexture(descriptor: cd, offset: 0, bytesPerRow: idWidth)!

        // 边界线
        let b = try Data(contentsOf: dir.appendingPathComponent("borders.bin"))
        let hdr = b.withUnsafeBytes { p in (0..<6).map { Int(p.load(fromByteOffset: $0 * 4, as: UInt32.self)) } }
        let nv = hdr[0], ni = hdr[1]
        countryLineRange = hdr[2]..<(hdr[2] + hdr[3])
        regionLineRange = hdr[4]..<(hdr[4] + hdr[5])
        let bv = b.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + 24, length: nv * 8, options: .storageModeShared)! }
        let bi = b.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress! + 24 + nv * 8, length: ni * 4, options: .storageModeShared)! }
        borderVertices = bv
        borderIndices = bi

        // 高程 → half
        let hd = try Data(contentsOf: dir.appendingPathComponent("height.bin"))
        let (hw, hh) = hd.withUnsafeBytes { (Int($0.load(fromByteOffset: 0, as: UInt32.self)), Int($0.load(fromByteOffset: 4, as: UInt32.self))) }
        let hraw = try GeoData.inflate(hd.dropFirst(8), expected: hw * hh * 2)
        var half = [Float16](repeating: 0, count: hw * hh)
        hraw.withUnsafeBytes { p in
            let s = p.bindMemory(to: Int16.self)
            for i in 0..<(hw * hh) { half[i] = Float16(Float(s[i])) }
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: hw, height: hh, mipmapped: false)
        td.usage = .shaderRead
        heightTexture = device.makeTexture(descriptor: td)!
        heightTexture.replace(region: MTLRegionMake2D(0, 0, hw, hh), mipmapLevel: 0, withBytes: half, bytesPerRow: hw * 2)
    }

    func country(_ id: Int) -> Country? { id > 0 && id <= countries.count ? countries[id - 1] : nil }
    func region(_ id: Int) -> Region? { id > 0 && id <= regions.count ? regions[id - 1] : nil }

    /// 经纬度 → (省级 ID, 国家 ID)，0 表示海洋或无。
    func lookup(lat: Double, lon: Double) -> (region: Int, country: Int) {
        var x = Int(((lon + 180) / 360 * Double(idWidth)).rounded(.down)) % idWidth
        if x < 0 { x += idWidth }
        let y = min(idHeight - 1, max(0, Int(((90 - lat) / 180 * Double(idHeight)).rounded(.down))))
        let i = y * idWidth + x
        let r = regionIDs.contents().load(fromByteOffset: i * 2, as: UInt16.self)
        let c = countryIDs.contents().load(fromByteOffset: i, as: UInt8.self)
        return (Int(r), Int(c))
    }

    static func inflate(_ data: Data, expected: Int) throws -> Data {
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw NSError(domain: "GeoData", code: 1, userInfo: [NSLocalizedDescriptionKey: "inflate \(written)/\(expected)"]) }
        return out
    }
}
