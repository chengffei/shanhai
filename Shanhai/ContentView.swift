import SwiftUI
import ImageIO

struct ContentView: View {
    @Bindable var controller: GlobeController
    @State private var query = ""

    private var hasSelection: Bool { controller.selectedCountry != 0 || controller.selectedRegion != 0 }

    var body: some View {
        ZStack(alignment: .trailing) {
            GlobeView(controller: controller)
                .ignoresSafeArea()
            if hasSelection {
                InfoPanel(controller: controller)
                    .frame(width: 380)
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: hasSelection)
        .overlay(alignment: .bottomLeading) { HoverName(controller: controller).padding(16) }
        .overlay(alignment: .bottomTrailing) {
            MapControls(controller: controller)
                .padding(16)
                .padding(.trailing, hasSelection ? 392 : 0)
                .animation(.smooth(duration: 0.25), value: hasSelection)
        }
        .overlay(alignment: .bottom) {
            if controller.mode == .terrain {
                Text("卫星影像 Sentinel-2 cloudless 2020 © EOX IT Services，含修改过的 Copernicus Sentinel 数据")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { DebugHooks.apply(controller) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("视图", selection: $controller.mode) {
                    Text("普通").tag(MapMode.political)
                    Text("地形").tag(MapMode.terrain)
                    Text("复古").tag(MapMode.vintage)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("普通：按国家上色的政区图；地形：卫星影像加真实起伏；复古：焦糖皮面地球仪")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索国家、省份或城市")
        .searchSuggestions {
            ForEach(SearchIndex.shared(controller.geo).find(query)) { hit in
                Button { go(hit) } label: {
                    HStack {
                        Text(hit.title)
                        Spacer()
                        Text(hit.subtitle).foregroundStyle(.secondary)
                    }
                }
                .searchCompletion(hit.title)
            }
        }
        .onSubmit(of: .search) {
            if let first = SearchIndex.shared(controller.geo).find(query).first { go(first) }
        }
    }

    private func go(_ hit: SearchIndex.Hit) {
        switch hit.kind {
        case .country(let id): controller.select(country: id)
        case .region(let id): controller.select(region: id)
        case .city(let lat, let lon):
            controller.fly(to: lat, lon: lon, extentDeg: 1.5)
            controller.select(lat: lat, lon: lon)
        }
        query = ""
    }
}

/// 右下角：放大、缩小、3D、指南针。给不会用触控板手势的人
struct MapControls: View {
    let controller: GlobeController
    var body: some View {
        VStack(spacing: 10) {
            Button { controller.home() } label: { Image(systemName: "globe.asia.australia") }
                .help("回到整个地球")
            Button { controller.toggle3D() } label: { Text(controller.camera.tilt > 0.05 ? "2D" : "3D").font(.system(size: 13, weight: .semibold)) }
                .help("倾斜视角，看山脉起伏（按住 Option 拖动也可以）")
                .disabled(controller.camera.maxTilt < 0.2)
            if abs(controller.camera.heading) > 0.01 {
                Button { controller.northUp() } label: {
                    Image(systemName: "location.north.line.fill").rotationEffect(.radians(-controller.camera.heading))
                }
                .help("回正，北朝上")
            }
            VStack(spacing: 0) {
                Button { controller.zoomAnimated(0.5) } label: { Image(systemName: "plus").frame(width: 36, height: 36).contentShape(Rectangle()) }
                Divider().frame(width: 20)
                Button { controller.zoomAnimated(2) } label: { Image(systemName: "minus").frame(width: 36, height: 36).contentShape(Rectangle()) }
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(MapButtonStyle())
        .font(.system(size: 15, weight: .medium))
    }
}

struct MapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 左下角显示鼠标所指的地名，帮完全不熟地理的人边看边认
struct HoverName: View {
    let controller: GlobeController
    var body: some View {
        let r = controller.geo.region(controller.hoverRegion)
        let c = controller.geo.country(controller.hoverCountry)
        if let c {
            HStack(spacing: 6) {
                if let r { Text(r.name).font(.headline) }
                Text(c.name).font(r == nil ? .headline : .subheadline).foregroundStyle(r == nil ? .primary : .secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// 中文名搜索：国家、省级区、城市
final class SearchIndex {
    enum Kind { case country(Int), region(Int), city(lat: Double, lon: Double) }
    struct Hit: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let kind: Kind
        let rank: Int
    }

    private static var instance: SearchIndex?
    static func shared(_ geo: GeoData) -> SearchIndex {
        if let i = instance { return i }
        let i = SearchIndex(geo: geo); instance = i; return i
    }

    private let items: [(key: String, hit: Hit)]

    private init(geo: GeoData) {
        var all: [(String, Hit)] = []
        for c in geo.countries {
            all.append((c.name + " " + c.nameEn.lowercased(), Hit(id: "c\(c.id)", title: c.name, subtitle: "国家", kind: .country(c.id), rank: 0)))
        }
        for r in geo.regions where r.pixels > 0 {
            let cn = geo.country(r.country)?.name ?? ""
            all.append((r.name + " " + r.nameEn.lowercased(), Hit(id: "r\(r.id)", title: r.name, subtitle: cn, kind: .region(r.id), rank: 1)))
        }
        for (i, c) in geo.cities.enumerated() where c.minZoom <= 7 {
            let hit = geo.lookup(lat: c.lat, lon: c.lon)
            let sub = [geo.region(hit.region)?.name, geo.country(hit.country)?.name].compactMap { $0 }.joined(separator: " · ")
            all.append((c.name, Hit(id: "t\(i)", title: c.name, subtitle: sub, kind: .city(lat: c.lat, lon: c.lon), rank: 2)))
        }
        items = all
    }

    func find(_ q: String) -> [Hit] {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var exact: [Hit] = [], prefix: [Hit] = [], contains: [Hit] = []
        for (key, hit) in items {
            if hit.title == q { exact.append(hit) }
            else if key.hasPrefix(q) { prefix.append(hit) }
            else if key.contains(q) { contains.append(hit) }
            if exact.count + prefix.count > 40 { break }
        }
        return Array((exact + prefix.sorted { $0.rank < $1.rank } + contains.sorted { $0.rank < $1.rank }).prefix(12))
    }
}

/// 调试用：SHANHAI_CAMERA="纬,经,高度,倾斜度数,朝向度数"  SHANHAI_MODE=terrain  SHANHAI_SELECT="纬,经"
/// SHANHAI_HOVER="纬,经"；启动 1 秒后在标准输出打印 WINDOW <窗口号>
enum DebugHooks {
    static func apply(_ c: GlobeController) {
        let env = ProcessInfo.processInfo.environment
        func nums(_ k: String) -> [Double]? { env[k].map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } } }
        if let v = nums("SHANHAI_CAMERA"), v.count >= 3 {
            var cam = Camera(lat: v[0], lon: v[1], altitude: v[2])
            if v.count > 3 { cam.tilt = v[3] * .pi / 180 }
            if v.count > 4 { cam.heading = v[4] * .pi / 180 }
            cam.clamp()
            c.camera = cam
        }
        if let m = env["SHANHAI_MODE"], let mode = MapMode(rawValue: m) { c.mode = mode }
        if let v = nums("SHANHAI_SELECT"), v.count == 2 { c.select(lat: v[0], lon: v[1]) }
        if let v = nums("SHANHAI_HOVER"), v.count == 2 { c.hover(lat: v[0], lon: v[1]) }
        // SHANHAI_ICON=输出.png：离屏渲染一张 2048² 地球后退出（SHANHAI_SKY=1 带太空背景）
        if let out = env["SHANHAI_ICON"] {
            func attempt() {
                guard let r = c.renderer, r.physicalReady else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: attempt); return
                }
                if let img = r.snapshot(camera: c.camera, terrain: c.mode == .terrain, selRegion: c.selectedRegion, selCountry: c.selectedCountry,
                                        size: 2048, sky: env["SHANHAI_SKY"] == "1"),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                }
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt)
        }
        if env["SHANHAI_PRINT_WINDOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let w = NSApp.windows.first(where: { $0.isVisible }) { print("WINDOW", w.windowNumber); fflush(stdout) }
            }
        }
    }
}
