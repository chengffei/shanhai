import AppKit
import CoreText
import Metal

/// 地名标签的字形缓存：用到哪个才排哪个，按行（shelf）塞进一张 RG8 纹理，R = 文字，G = 白边。
/// 塞满了就整张清空重来，下一帧把屏幕上的重新排进去。显存固定 16 MB。
final class LabelAtlas {
    enum Style { case country, region, city, capital }
    struct Entry {
        var uv: SIMD4<Float>      // x0 y0 x1 y1
        var size: SIMD2<Float>    // 点
        var anchor: SIMD2<Float>  // 地点在标签内的位置（点，左上原点）
    }

    let texture: MTLTexture
    static let scale: CGFloat = 2
    static let width = 4096, height = 2048
    private var entries: [Int: Entry] = [:]
    private var x = 0, y = 0, rowH = 0
    private(set) var generation = 0         // 清空过几次；用来让渲染器知道要重排

    private let fonts: [Style: NSFont] = [
        .country: .systemFont(ofSize: 13, weight: .semibold),
        .region: .systemFont(ofSize: 11, weight: .regular),
        .city: .systemFont(ofSize: 11, weight: .regular),
        .capital: .systemFont(ofSize: 11.5, weight: .semibold),
    ]
    private static let pad: CGFloat = 3
    private static let dot: CGFloat = 9     // 城市标签左侧圆点占的宽度

    init?(device: MTLDevice) {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: LabelAtlas.width, height: LabelAtlas.height, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        texture = tex
    }

    /// 取标签；没排过就现排。返回 nil 表示图集刚满、本帧放弃
    func entry(key: Int, text: String, style: Style) -> Entry? {
        if let e = entries[key] { return e }
        return rasterize(key: key, text: text, style: style)
    }

    func reset() {
        entries.removeAll(keepingCapacity: true)
        x = 0; y = 0; rowH = 0
        generation += 1
    }

    private func rasterize(key: Int, text: String, style: Style) -> Entry? {
        let font = fonts[style]!
        let isCity = style == .city || style == .capital
        let pad = LabelAtlas.pad, s = LabelAtlas.scale
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let lead = isCity ? LabelAtlas.dot : 0
        let wPt = ceil(textW + lead + pad * 2), hPt = ceil(font.ascender - font.descender + pad * 2)
        let wPx = Int(wPt * s), hPx = Int(hPt * s)
        if x + wPx > LabelAtlas.width { x = 0; y += rowH; rowH = 0 }
        if y + hPx > LabelAtlas.height { reset(); return nil }

        let space = CGColorSpaceCreateDeviceGray()
        guard let fill = CGContext(data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: wPx, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let halo = CGContext(data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: wPx, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        for c in [fill, halo] {
            c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: wPx, height: hPx))
            c.scaleBy(x: s, y: s)
            c.setFillColor(gray: 1, alpha: 1)
            c.setStrokeColor(gray: 1, alpha: 1)
        }
        let baseX = pad + lead, baseY = pad - font.descender
        fill.textPosition = CGPoint(x: baseX, y: baseY)
        CTLineDraw(line, fill)
        // 白边：每个字形描 3 点粗的边
        halo.setLineWidth(3); halo.setLineJoin(.round)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<n {
                guard let path = CTFontCreatePathForGlyph(rf, glyphs[i], nil) else { continue }
                halo.saveGState()
                halo.translateBy(x: baseX + pos[i].x, y: baseY + pos[i].y)
                halo.addPath(path)
                halo.drawPath(using: .fillStroke)
                halo.restoreGState()
            }
        }
        var anchor = SIMD2<Float>(Float(wPt / 2), Float(hPt / 2))
        if isCity {
            let r: CGFloat = style == .capital ? 3.2 : 2.6
            let cx = pad + lead / 2 - 1, cy = hPt / 2
            fill.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            halo.fillEllipse(in: CGRect(x: cx - r - 1.5, y: cy - r - 1.5, width: r * 2 + 3, height: r * 2 + 3))
            anchor = SIMD2(Float(cx), Float(hPt - cy))
        }

        let fp = fill.data!.assumingMemoryBound(to: UInt8.self), hp = halo.data!.assumingMemoryBound(to: UInt8.self)
        var rg = [UInt8](repeating: 0, count: wPx * hPx * 2)
        for i in 0..<(wPx * hPx) { rg[i * 2] = fp[i]; rg[i * 2 + 1] = hp[i] }
        texture.replace(region: MTLRegionMake2D(x, y, wPx, hPx), mipmapLevel: 0, withBytes: rg, bytesPerRow: wPx * 2)

        let W = Float(LabelAtlas.width), H = Float(LabelAtlas.height)
        let e = Entry(uv: SIMD4(Float(x) / W, Float(y) / H, Float(x + wPx) / W, Float(y + hPx) / H),
                      size: SIMD2(Float(wPt), Float(hPt)), anchor: anchor)
        entries[key] = e
        x += wPx; rowH = max(rowH, hPx)
        return e
    }
}
