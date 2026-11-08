import SwiftUI
import ImageIO

struct ContentView: View {
    @Bindable var controller: GlobeController
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// 第一次选中过任何地方后不再显示引导
    @AppStorage("hasSelectedOnce") private var hasSelectedOnce = false

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
        .onChange(of: hasSelection, initial: true) { _, open in
            controller.rightInset = open ? 392 : 0
            if open { hasSelectedOnce = true }
        }
        .overlay(alignment: .bottom) {
            if controller.climateOn {
                MonsoonBar(controller: controller)
                    .padding(.bottom, 24)
                    .padding(.trailing, hasSelection ? 392 : 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !hasSelectedOnce && !hasSelection {
                CoachMark { hasSelectedOnce = true }
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if controller.loadingStyle {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备\(controller.mode.title)底图…").font(.callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: controller.loadingStyle)
        .animation(.smooth(duration: 0.3), value: controller.climateOn)
        .onChange(of: controller.searchRequest) { searchFocused = true }
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
            ToolbarItemGroup(placement: .principal) {
                Picker("视图", selection: $controller.mode) {
                    Text("普通").tag(MapMode.political)
                    Text("地形").tag(MapMode.terrain)
                    Text("复古").tag(MapMode.vintage)
                    Text("黑金").tag(MapMode.blackgold)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .help("普通：按国家上色的政区图；地形：卫星影像加立体浮雕；复古：焦糖皮面地球仪；黑金：黑漆金箔地球仪")
                Group {
                if controller.climateOn {
                    Button { controller.toggleClimate() } label: { Label("季风", systemImage: "wind") }
                        .buttonStyle(.glassProminent)
                        .tint(Color(red: controller.mode.linkColor.0, green: controller.mode.linkColor.1, blue: controller.mode.linkColor.2))
                        .labelStyle(.titleAndIcon)
                } else {
                    Button { controller.toggleClimate() } label: { Label("季风", systemImage: "wind") }
                        .labelStyle(.titleAndIcon)
                }
                }
                .help("季风：一年里风向随季节反过来。夏天陆地比海洋热，海风带着水汽吹进大陆，下雨多；冬天反过来，风从大陆吹向海洋，天气干")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索国家、省份或城市")
        .searchFocused($searchFocused)
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

/// 季风图层的时间轴：播放、拖动月份、当月一句解说、图例
struct MonsoonBar: View {
    let controller: GlobeController

    private static let captions: [String] = [
        "冬季风：大陆比海洋冷，风从陆地吹向海洋，南亚、东亚干燥少雨",   // 1
        "冬季风：大陆比海洋冷，风从陆地吹向海洋，南亚、东亚干燥少雨",   // 2
        "风向转换期：太阳往北移，雨带跟着往北走",                       // 3
        "风向转换期：太阳往北移，雨带跟着往北走",                       // 4
        "夏季风登场：华南进入雨季，印度还在等雨",                       // 5
        "夏季风推进：印度雨季开始，长江流域进入梅雨",                   // 6
        "夏季风最盛：大陆比海洋热，湿润的海风吹进陆地，雨带到最北",     // 7
        "夏季风最盛：大陆比海洋热，湿润的海风吹进陆地，雨带到最北",     // 8
        "夏季风减弱：雨带开始往南撤",                                   // 9
        "风向转回：冬季风建立，北方转干，雨带退回赤道附近",             // 10
        "风向转回：冬季风建立，北方转干，雨带退回赤道附近",             // 11
        "冬季风：大陆比海洋冷，风从陆地吹向海洋，南亚、东亚干燥少雨",   // 12
    ]

    var body: some View {
        let m = controller.climateMonthIndex
        let sw = Swatches(controller.mode)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { controller.climatePlaying.toggle() } label: {
                    Image(systemName: controller.climatePlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(controller.climatePlaying ? "暂停" : "播放：每 2 秒走一个月")
                Text("\(m + 1) 月")
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .leading)
                    .contentTransition(.numericText())
                Slider(value: Binding(get: { controller.climateMonthShown },
                                      set: { controller.climatePlaying = false; controller.climateMonth = $0 }),
                       in: 0...11.99)
                    .help("拖动看不同月份")
            }
            Text(Self.captions[m])
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                LegendItem(title: "地面风") { Capsule().fill(sw.wind).frame(width: 18, height: 2.5) }
                LegendItem(title: "雨多") { RoundedRectangle(cornerRadius: 3).fill(sw.rain.opacity(0.7)).frame(width: 14, height: 10) }
                LegendItem(title: "雨带中心") {
                    Path { p in p.move(to: CGPoint(x: 0, y: 1.5)); p.addLine(to: CGPoint(x: 18, y: 1.5)) }
                        .stroke(sw.band, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 18, height: 3)
                }
                LegendItem(title: "季风区") { RoundedRectangle(cornerRadius: 3).stroke(sw.monsoon, lineWidth: 1.8).frame(width: 14, height: 10) }
                Spacer(minLength: 0)
                Text("1991–2020 气候平均").foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 540)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// 图例颜色和着色器里各风格的颜色对应
    private struct Swatches {
        let wind: Color, rain: Color, band: Color, monsoon: Color
        init(_ mode: MapMode) {
            switch mode {
            case .terrain:
                wind = .primary; rain = Color(red: 0.28, green: 0.68, blue: 1.0)
                band = Color(red: 0.35, green: 0.85, blue: 1.0); monsoon = Color(red: 1.0, green: 0.60, blue: 0.22)
            case .vintage:
                wind = Color(red: 0.26, green: 0.12, blue: 0.04); rain = Color(red: 0.10, green: 0.30, blue: 0.40)
                band = Color(red: 0.10, green: 0.28, blue: 0.36); monsoon = Color(red: 0.62, green: 0.16, blue: 0.08)
            case .blackgold:
                wind = Color(red: 0.75, green: 0.60, blue: 0.30); rain = Color(red: 0.28, green: 0.74, blue: 0.84)
                band = Color(red: 0.35, green: 0.70, blue: 0.85); monsoon = Color(red: 1.0, green: 0.60, blue: 0.22)
            case .political:
                wind = Color(red: 0.06, green: 0.14, blue: 0.32); rain = Color(red: 0.04, green: 0.36, blue: 0.88)
                band = Color(red: 0.02, green: 0.22, blue: 0.62); monsoon = Color(red: 0.90, green: 0.36, blue: 0.08)
            }
        }
    }
}

private struct LegendItem<Mark: View>: View {
    let title: String
    @ViewBuilder let mark: () -> Mark
    var body: some View {
        HStack(spacing: 5) {
            mark()
            Text(title).foregroundStyle(.secondary)
        }
    }
}

/// 第一次打开时的一句引导：告诉零基础的人能做什么
struct CoachMark: View {
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap").font(.system(size: 15, weight: .medium))
            Text("点一下任意国家，看它的介绍；放大后可以点省份").font(.callout)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("不再提示")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
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
                .help("倾斜视角看山脉起伏，地形视图下最明显；离得远时会先飞近（按住 Option 拖动也可以）")
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
/// SHANHAI_HOVER="纬,经"；SHANHAI_PRESS_3D=1 启动 1 秒后按一下 3D；启动 1 秒后在标准输出打印 WINDOW <窗口号>
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
        if let v = nums("SHANHAI_MONSOON"), let m = v.first {
            // SHANHAI_MONSOON=月份（1–12）：打开季风并停在该月
            c.climateOn = true; c.climatePlaying = env["SHANHAI_PLAY"] != nil; c.climateMonth = m - 1
        }
        if env["SHANHAI_HOVER_STORM"] != nil {
            // 调试：模拟鼠标在地图上来回移动（120 Hz）
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
                t += 1.0 / 120
                c.hover(lat: 30 + 15 * sin(t * 0.7), lon: 100 + 30 * sin(t * 0.4))
            }
        }
        if let m = env["SHANHAI_MODE"], let mode = MapMode(rawValue: m) { c.mode = mode }
        if let v = nums("SHANHAI_SELECT"), v.count == 2 { c.select(lat: v[0], lon: v[1]) }
        if let v = nums("SHANHAI_HOVER"), v.count == 2 { c.hover(lat: v[0], lon: v[1]) }
        if env["SHANHAI_PRESS_3D"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.toggle3D() } }
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
