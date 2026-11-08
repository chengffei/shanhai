import MetalKit
import simd

struct Uniforms {
    var viewProj = simd_float4x4()
    var invViewProj = simd_float4x4()
    var eye = SIMD4<Float>()
    var light = SIMD4<Float>()
    var params = SIMD4<Float>()
    var sel = SIMD4<UInt32>()
    var viewport = SIMD4<Float>()
}

struct LabelInstance {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var uv: SIMD4<Float>
    var style: SIMD4<Float>
}

/// 按需绘制：只有相机、选中、模式变化时才出新帧。
final class GlobeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let geo: GeoData
    weak var controller: GlobeController?

    private var globePSO: MTLRenderPipelineState!
    private var linePSO: MTLRenderPipelineState!
    private var skyPSO: MTLRenderPipelineState!
    private var labelPSO: MTLRenderPipelineState!
    private var depthOn: MTLDepthStencilState!
    private var depthRead: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!
    private struct Mesh { let uv: MTLBuffer; let index: MTLBuffer; let count: Int }
    private var smoothMesh: Mesh!      // 512×256：没有起伏时球面够圆
    private var reliefMesh: Mesh!      // 2048×1024：地形视图，约 20 km 一格
    private var political: MTLTexture!
    private var physical: MTLTexture?
    private var vintage: MTLTexture?
    private var vintageLoading = false
    private let geoDir = Bundle.main.resourceURL!.appendingPathComponent("Geo")

    /// 复古底图第一次用到时才后台加载（约 90 MB 显存）
    private func vintageTexture() -> MTLTexture? {
        if let vintage { return vintage }
        if !vintageLoading {
            vintageLoading = true
            let loader = MTKTextureLoader(device: device), dir = geoDir
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let t = try? GlobeRenderer.loadBase(loader, dir, "vintage")
                DispatchQueue.main.async { self?.vintage = t; self?.controller?.requestRedraw(); malloc_zone_pressure_relief(nil, 0) }
            }
        }
        return nil
    }

    /// 当前风格实际用的底图与风格编号（底图还没加载好时先退回普通）
    private func baseFor(_ mode: MapMode) -> (MTLTexture, Float) {
        switch mode {
        case .terrain: if let physical { return (physical, 1) }
        case .vintage: if let v = vintageTexture() { return (v, 2) }
        case .political: break
        }
        return (political, 0)
    }
    private var atlas: LabelAtlas?
    private var labelBuffer: MTLBuffer
    private var labelCount = 0
    private static let maxLabels = 1500

    static let samples = 4
    // MSAA 颜色与深度只活在 GPU 片上内存（memoryless），不占显存，解析后直接写进 drawable
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?

    private func passDescriptor(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let t = drawable.texture
        if msaaColor?.width != t.width || msaaColor?.height != t.height {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width, height: t.height, mipmapped: false)
            cd.textureType = .type2DMultisample; cd.sampleCount = GlobeRenderer.samples
            cd.storageMode = .memoryless; cd.usage = .renderTarget
            msaaColor = device.makeTexture(descriptor: cd)
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: t.width, height: t.height, mipmapped: false)
            dd.textureType = .type2DMultisample; dd.sampleCount = GlobeRenderer.samples
            dd.storageMode = .memoryless; dd.usage = .renderTarget
            msaaDepth = device.makeTexture(descriptor: dd)
        }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = msaaColor
        p.colorAttachments[0].resolveTexture = t
        p.colorAttachments[0].loadAction = .dontCare      // 天空每帧铺满全屏
        p.colorAttachments[0].storeAction = .multisampleResolve
        p.depthAttachment.texture = msaaDepth
        p.depthAttachment.loadAction = .clear
        p.depthAttachment.clearDepth = 1
        p.depthAttachment.storeAction = .dontCare
        return p
    }

    private(set) var invViewProj = simd_double4x4()
    private(set) var eye = SIMD3<Double>()

    init(view: MTKView, geo: GeoData) throws {
        device = view.device!
        queue = device.makeCommandQueue()!
        self.geo = geo
        labelBuffer = device.makeBuffer(length: MemoryLayout<LabelInstance>.stride * GlobeRenderer.maxLabels, options: .storageModeShared)!
        super.init()
        try buildPipelines(view: view)
        smoothMesh = buildMesh(columns: 512, rows: 256)
        reliefMesh = buildMesh(columns: 2048, rows: 1024)
        let loader = MTKTextureLoader(device: device)
        let geoDir = Bundle.main.resourceURL!.appendingPathComponent("Geo")
        political = try GlobeRenderer.loadBase(loader, geoDir, "political")
        atlas = LabelAtlas(device: device)
        // 地形底图放后台，先出画面
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let phys = try? GlobeRenderer.loadBase(loader, geoDir, "physical")
            DispatchQueue.main.async {
                self?.physical = phys
                self?.controller?.requestRedraw()
                // 加载与建网格时的大块临时内存已释放，但分配器会留着；主动还给系统
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    /// 优先读 BC1 压缩的 KTX（自带 mipmap，直接进显存）；没有就退回 JPG
    private static func loadBase(_ loader: MTKTextureLoader, _ dir: URL, _ name: String) throws -> MTLTexture {
        let ktx = dir.appendingPathComponent("\(name).ktx")
        if FileManager.default.fileExists(atPath: ktx.path) {
            return try loader.newTexture(URL: ktx, options: [.textureStorageMode: MTLStorageMode.private.rawValue])
        }
        return try loader.newTexture(URL: dir.appendingPathComponent("\(name).jpg"),
                                     options: [.generateMipmaps: true, .SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
    }

    private func buildPipelines(view: MTKView) throws {
        // 着色器在运行时编译：不依赖 Xcode 的 Metal 工具链，系统会缓存编译结果
        let url = Bundle.main.url(forResource: "Shaders", withExtension: "msl")!
        let lib = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pso(_ v: String, _ f: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = GlobeRenderer.samples
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        globePSO = try pso("globe_vertex", "globe_fragment", blend: false)
        linePSO = try pso("line_vertex", "line_fragment", blend: true)
        skyPSO = try pso("sky_vertex", "sky_fragment", blend: false)
        labelPSO = try pso("label_vertex", "label_fragment", blend: true)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
        depthOn = device.makeDepthStencilState(descriptor: dd)
        dd.depthCompareFunction = .lessEqual; dd.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: dd)
        dd.depthCompareFunction = .always; dd.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: dd)
    }

    /// 经纬网格，直接写进共享显存，不留临时数组（2048×1024 的索引有 50 MB）
    private func buildMesh(columns: Int, rows: Int) -> Mesh {
        let nv = (columns + 1) * (rows + 1), ni = columns * rows * 6
        let uvBuf = device.makeBuffer(length: nv * 8, options: .storageModeShared)!
        let idxBuf = device.makeBuffer(length: ni * 4, options: .storageModeShared)!
        let uv = uvBuf.contents().bindMemory(to: SIMD2<Float>.self, capacity: nv)
        var k = 0
        for r in 0...rows {
            for c in 0...columns { uv[k] = SIMD2(Float(c) / Float(columns), Float(r) / Float(rows)); k += 1 }
        }
        let idx = idxBuf.contents().bindMemory(to: UInt32.self, capacity: ni)
        let stride = UInt32(columns + 1)
        k = 0
        for r in 0..<UInt32(rows) {
            for c in 0..<UInt32(columns) {
                let a = r * stride + c, b = a + 1, d = a + stride, e = d + 1
                idx[k] = a; idx[k + 1] = d; idx[k + 2] = b
                idx[k + 3] = b; idx[k + 4] = d; idx[k + 5] = e
                k += 6
            }
        }
        return Mesh(uv: uvBuf, index: idxBuf, count: ni)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { controller?.requestRedraw() }

    var physicalReady: Bool { physical != nil }

    /// 离屏渲染一张正方形地球（做图标用）：不画标签；sky = false 时背景透明
    func snapshot(camera cam: Camera, terrain wantTerrain: Bool, selRegion: Int, selCountry: Int, size: Int, sky: Bool) -> CGImage? {
        let terrain = wantTerrain && physical != nil
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        rd.usage = [.renderTarget, .shaderRead]; rd.storageMode = .shared
        guard let target = device.makeTexture(descriptor: rd) else { return nil }
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        md.textureType = .type2DMultisample; md.sampleCount = GlobeRenderer.samples; md.usage = .renderTarget; md.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        dd.textureType = .type2DMultisample; dd.sampleCount = GlobeRenderer.samples; dd.usage = .renderTarget; dd.storageMode = .private
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = device.makeTexture(descriptor: md)
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = device.makeTexture(descriptor: dd)
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 1; pass.depthAttachment.storeAction = .dontCare

        let m = cam.matrices(aspect: 1)
        let vp = m.proj * m.view
        let e = cam.frame.eye, f = cam.frame
        var u = Uniforms()
        u.viewProj = vp.float; u.invViewProj = vp.inverse.float
        u.eye = SIMD4(Float(e.x), Float(e.y), Float(e.z), 0)
        let l = simd_normalize(f.eye - f.target * 0.2 + f.up * 0.6 - simd_cross(f.up, f.eye) * 0.4)
        u.light = SIMD4(Float(l.x), Float(l.y), Float(l.z), 0)
        u.params = SIMD4(terrain ? Float(cam.reliefExaggeration / 6_371_000) : 0, regionLineAlpha(cam), 0.55, terrain ? 1 : 0)
        u.sel = SIMD4(UInt32(selRegion), UInt32(selCountry), 0, 0)
        u.viewport = SIMD4(Float(size), Float(size), 2, Float(cam.altitude))

        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        if sky {
            enc.setRenderPipelineState(skyPSO); enc.setDepthStencilState(depthOff)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.setRenderPipelineState(globePSO); enc.setDepthStencilState(depthOn)
        enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
        let mesh = terrain ? reliefMesh! : smoothMesh!
        enc.setVertexBuffer(mesh.uv, offset: 0, index: 0)
        enc.setVertexTexture(geo.heightTexture, index: 0)
        enc.setFragmentTexture(terrain ? physical! : political, index: 0)
        enc.setFragmentTexture(geo.regionTexture, index: 1)
        enc.setFragmentTexture(geo.countryTexture, index: 2)
        enc.setFragmentTexture(geo.heightTexture, index: 3)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.index, indexBufferOffset: 0)
        enc.setCullMode(.none); enc.setRenderPipelineState(linePSO); enc.setDepthStencilState(depthRead)
        enc.setVertexBuffer(geo.borderVertices, offset: 0, index: 0)
        func lines(_ range: Range<Int>, color: SIMD4<Float>, width: Int) {
            guard !range.isEmpty else { return }
            var c = color
            enc.setFragmentBytes(&c, length: 16, index: 0)
            enc.drawIndexedPrimitives(type: .lineStrip, indexCount: range.count, indexType: .uint32, indexBuffer: geo.borderIndices,
                                      indexBufferOffset: range.lowerBound * 4, instanceCount: width)
        }
        let ink: SIMD3<Float> = terrain ? SIMD3(1, 1, 1) : SIMD3(0.25, 0.27, 0.32)
        lines(geo.countryLineRange, color: SIMD4(ink, terrain ? 0.6 : 0.55), width: 2)
        if let r = geo.region(selRegion) { for o in r.outline { lines(o[0]..<(o[0] + o[1]), color: SIMD4(0, 0.48, 1, 1), width: 9) } }
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        // 着色器输出预乘 alpha；天空不透明。BGRA → CGImage
        let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return ctx?.makeImage()
    }

    // SHANHAI_PERF=1：持续自转并每 2 秒打印帧耗时
    private let perf = ProcessInfo.processInfo.environment["SHANHAI_PERF"] != nil
    private var perfGPU: [Double] = [], perfCPU: [Double] = [], perfLast = CACurrentMediaTime()

    func draw(in view: MTKView) {
        let t0 = CACurrentMediaTime()
        if perf, let c = controller {
            view.isPaused = false
            var cam = c.camera; cam.lon += 0.25; c.camera = cam
        }
        guard let controller, let drawable = view.currentDrawable else { return }
        let pass = passDescriptor(for: drawable)
        controller.stepAnimation()
        let cam = controller.camera
        let size = view.drawableSize
        let scale = view.window?.backingScaleFactor ?? 2
        let m = cam.matrices(aspect: size.width / max(size.height, 1))
        let vp = m.proj * m.view
        invViewProj = vp.inverse
        eye = cam.frame.eye

        let (baseTex, style) = baseFor(controller.mode)
        let terrain = style == 1
        var u = Uniforms()
        u.viewProj = vp.float
        u.invViewProj = invViewProj.float
        u.eye = SIMD4(Float(eye.x), Float(eye.y), Float(eye.z), 0)
        // 光从相机左上方来，旋转地球时光跟着视角走
        let f = cam.frame
        let l = simd_normalize(f.eye - f.target * 0.2 + f.up * 0.6 - simd_cross(f.up, f.eye) * 0.4)
        u.light = SIMD4(Float(l.x), Float(l.y), Float(l.z), 0)
        let exaggeration: Float = terrain ? Float(cam.reliefExaggeration / 6_371_000) : 0
        u.params = SIMD4(exaggeration, regionLineAlpha(cam), 0.55, style)
        u.sel = SIMD4(UInt32(controller.selectedRegion), UInt32(controller.selectedCountry), UInt32(controller.hoverRegion), UInt32(controller.hoverCountry))
        u.viewport = SIMD4(Float(size.width), Float(size.height), Float(scale), Float(cam.altitude))

        updateLabels(camera: cam, vp: vp, size: size, scale: scale, terrain: terrain)

        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)

        enc.setRenderPipelineState(skyPSO)
        enc.setDepthStencilState(depthOff)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(globePSO)
        enc.setDepthStencilState(depthOn)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)
        let mesh = terrain ? reliefMesh! : smoothMesh!
        enc.setVertexBuffer(mesh.uv, offset: 0, index: 0)
        enc.setVertexTexture(geo.heightTexture, index: 0)
        enc.setFragmentTexture(baseTex, index: 0)
        enc.setFragmentTexture(geo.regionTexture, index: 1)
        enc.setFragmentTexture(geo.countryTexture, index: 2)
        enc.setFragmentTexture(geo.heightTexture, index: 3)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.index, indexBufferOffset: 0)

        enc.setCullMode(.none)
        enc.setRenderPipelineState(linePSO)
        enc.setDepthStencilState(depthRead)
        enc.setVertexBuffer(geo.borderVertices, offset: 0, index: 0)
        func lines(_ range: Range<Int>, color: SIMD4<Float>, width: Int) {
            guard !range.isEmpty, color.w > 0.01 else { return }
            var c = color
            enc.setFragmentBytes(&c, length: 16, index: 0)
            enc.drawIndexedPrimitives(type: .lineStrip, indexCount: range.count, indexType: .uint32, indexBuffer: geo.borderIndices,
                                      indexBufferOffset: range.lowerBound * 4, instanceCount: width)
        }
        let ink: SIMD3<Float> = terrain ? SIMD3(1, 1, 1) : (style == 2 ? SIMD3(0.28, 0.15, 0.08) : SIMD3(0.25, 0.27, 0.32))
        lines(geo.regionLineRange, color: SIMD4(ink, u.params.y * (terrain ? 0.5 : (style == 2 ? 0.35 : 0.45))), width: 1)
        lines(geo.countryLineRange, color: SIMD4(ink, terrain ? 0.75 : (style == 2 ? 0.5 : 0.6)), width: scale > 1 ? 2 : 1)
        let accent = style == 2 ? SIMD4<Float>(1.0, 0.86, 0.58, 1.0) : SIMD4<Float>(0.0, 0.48, 1.0, 1.0)
        if let r = geo.region(controller.selectedRegion) {
            for o in r.outline { lines(o[0]..<(o[0] + o[1]), color: accent, width: 4) }
        } else if let c = geo.country(controller.selectedCountry) {
            for o in c.outline { lines(o[0]..<(o[0] + o[1]), color: accent, width: 4) }
        }

        if labelCount > 0, let atlas {
            enc.setRenderPipelineState(labelPSO)
            enc.setDepthStencilState(depthOff)
            enc.setVertexBuffer(labelBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: labelCount)
        }
        enc.endEncoding()
        cb.present(drawable)
        if perf {
            cb.addCompletedHandler { [weak self] b in
                let g = (b.gpuEndTime - b.gpuStartTime) * 1000
                DispatchQueue.main.async { self?.perfGPU.append(g) }
            }
            perfCPU.append((CACurrentMediaTime() - t0) * 1000)
            if CACurrentMediaTime() - perfLast > 2, !perfGPU.isEmpty {
                let avg = { (a: [Double]) in a.reduce(0, +) / Double(a.count) }
                print(String(format: "PERF frames %d  gpu avg %.2f ms max %.2f  cpu avg %.2f ms max %.2f  labels %d",
                             perfCPU.count, avg(perfGPU), perfGPU.max()!, avg(perfCPU), perfCPU.max()!, labelCount)); fflush(stdout)
                perfGPU.removeAll(); perfCPU.removeAll(); perfLast = CACurrentMediaTime()
            }
        }
        cb.commit()
    }

    /// 省界在远处淡出，免得整个地球糊成一团线
    private func regionLineAlpha(_ cam: Camera) -> Float {
        // 在省级阈值上下 0.3 内淡入：阈值处正好一半
        let a = cam.altitude, t = Camera.provinceAltitude
        return Float(max(0, min(1, (t + 0.3 - a) / 0.6)))
    }

    // MARK: 标签布局

    /// 每帧重排：按优先级（选中 > 国家 > 省 > 城市）贪心放置，互相不重叠
    private func updateLabels(camera: Camera, vp: simd_double4x4, size: CGSize, scale: CGFloat, terrain: Bool) {
        guard let atlas, ProcessInfo.processInfo.environment["SHANHAI_NOLABELS"] == nil else { labelCount = 0; return }
        let gen = atlas.generation
        layoutLabels(atlas: atlas, camera: camera, vp: vp, size: size, scale: scale)
        if atlas.generation != gen {
            // 图集满了被清空：已排的 uv 失效，重排一次
            layoutLabels(atlas: atlas, camera: camera, vp: vp, size: size, scale: scale)
        }
    }

    private func layoutLabels(atlas: LabelAtlas, camera: Camera, vp: simd_double4x4, size: CGSize, scale: CGFloat) {
        let eye = camera.frame.eye
        let span = 2 * camera.altitude * tan(Camera.fovY / 2)
        let pxPerRadian = Double(size.height) / max(span, 1e-6)
        let heightPt = Double(size.height / scale)
        // 与网页地图缩放级别对齐，方便用 Natural Earth 的 min_zoom
        let zoom = log2(heightPt * 360 / (256 * min(span, 2.2) * 180 / .pi))
        let out = labelBuffer.contents().bindMemory(to: LabelInstance.self, capacity: GlobeRenderer.maxLabels)
        var grid = CollisionGrid(width: Double(size.width), height: Double(size.height), cell: 64)
        var n = 0
        let s = Float(scale)

        func project(_ lon: Double, _ lat: Double) -> CGPoint? {
            let la = lat * .pi / 180, lo = lon * .pi / 180
            let p = SIMD3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
            guard simd_dot(p, simd_normalize(eye - p)) > 0.18 else { return nil }   // 贴着地球边缘的不标
            let c = vp * SIMD4(p, 1)
            guard c.w > 0 else { return nil }
            let x = (c.x / c.w * 0.5 + 0.5) * size.width, y = (0.5 - c.y / c.w * 0.5) * size.height
            guard x > -80, y > -30, x < size.width + 80, y < size.height + 30 else { return nil }
            return CGPoint(x: x, y: y)
        }
        @discardableResult
        func place(key: Int, text: String, style: LabelAtlas.Style, lon: Double, lat: Double) -> Bool {
            guard n < GlobeRenderer.maxLabels, let pt = project(lon, lat) else { return false }
            guard let e = atlas.entry(key: key, text: text, style: style) else { return false }
            let w = Double(e.size.x * s), h = Double(e.size.y * s)
            let x0 = Double(pt.x) - Double(e.anchor.x * s), y0 = Double(pt.y) - Double(e.anchor.y * s)
            let r = CGRect(x: x0, y: y0, width: w, height: h).insetBy(dx: Double(-3 * scale), dy: Double(-1 * scale))
            guard grid.insertIfFree(r) else { return false }
            let kind: Float
            switch style {
            case .country: kind = 1
            case .region: kind = 0
            case .ocean, .sea: kind = 3
            default: kind = 2
            }
            out[n] = LabelInstance(center: SIMD2(Float(x0 + w / 2), Float(y0 + h / 2)), size: SIMD2(Float(w), Float(h)), uv: e.uv, style: SIMD4(kind, 1, 0, 0))
            n += 1
            return true
        }

        let showRegions = camera.showsProvinces
        if let r = geo.region(controller?.selectedRegion ?? 0) {
            place(key: r.id, text: r.name, style: .region, lon: r.label[0], lat: r.label[1])
        }
        for c in labelOrderCountries {
            // 用面积而不是外接框：散布的群岛外接框很大，实际很小
            let extentPx = sqrt(max(c.area, 1)) / 6371 * pxPerRadian
            guard extentPx > Double(40 * scale) || (c.labelRank <= 2 && extentPx > Double(18 * scale)) else { continue }
            if showRegions && extentPx > Double(size.height) * 1.6 { continue }   // 太近时让位给省名
            place(key: -c.id, text: c.name, style: .country, lon: c.label[0], lat: c.label[1])
        }
        // 海洋名：大洋始终显示，海、湾按 Natural Earth 的 min_label 随放大出现
        for (i, m) in geo.marine.enumerated() where m.minLabel <= zoom + 0.4 {
            place(key: 2_000_000 + i, text: m.name, style: m.kind == "ocean" ? .ocean : .sea, lon: m.lon, lat: m.lat)
        }
        // 首都和大城市先于省名，近处才轮到普通城市
        for (i, c) in geo.cities.enumerated() where c.minZoom <= zoom - 0.6 && (c.cap == 2 || c.minZoom <= zoom - 1.6) {
            place(key: 1_000_000 + i, text: c.name, style: c.cap == 2 ? .capital : .city, lon: c.lon, lat: c.lat)
        }
        if showRegions {
            for r in labelOrderRegions {
                let extentPx = sqrt(max(r.area ?? 1, 1)) / 6371 * pxPerRadian
                guard extentPx > Double(45 * scale) else { continue }
                place(key: r.id, text: r.name, style: .region, lon: r.label[0], lat: r.label[1])
            }
        }
        for (i, c) in geo.cities.enumerated() where c.minZoom <= zoom - 0.6 && !(c.cap == 2 || c.minZoom <= zoom - 1.6) {
            place(key: 1_000_000 + i, text: c.name, style: c.cap > 0 ? .capital : .city, lon: c.lon, lat: c.lat)
        }
        labelCount = n
    }

    private lazy var labelOrderCountries: [Country] = geo.countries.sorted { ($0.labelRank, -$0.pop) < ($1.labelRank, -$1.pop) }
    private lazy var labelOrderRegions: [Region] = geo.regions.filter { $0.pixels > 0 }.sorted { ($0.area ?? 0) > ($1.area ?? 0) }
}

/// 均匀网格加速的矩形碰撞
struct CollisionGrid {
    let cols: Int, rows: Int, cell: Double
    var buckets: [[CGRect]]
    init(width: Double, height: Double, cell: Double) {
        self.cell = cell
        cols = max(1, Int(width / cell) + 3); rows = max(1, Int(height / cell) + 3)
        buckets = Array(repeating: [], count: cols * rows)
    }
    private func range(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>) {
        let x0 = max(0, min(cols - 1, Int(Double(r.minX) / cell) + 1)), x1 = max(0, min(cols - 1, Int(Double(r.maxX) / cell) + 1))
        let y0 = max(0, min(rows - 1, Int(Double(r.minY) / cell) + 1)), y1 = max(0, min(rows - 1, Int(Double(r.maxY) / cell) + 1))
        return (x0...x1, y0...y1)
    }
    mutating func insertIfFree(_ r: CGRect) -> Bool {
        let (xs, ys) = range(r)
        for y in ys { for x in xs where buckets[y * cols + x].contains(where: { $0.intersects(r) }) { return false } }
        for y in ys { for x in xs { buckets[y * cols + x].append(r) } }
        return true
    }
}
