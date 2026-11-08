import SwiftUI

@main
struct ShanhaiApp: App {
    @State private var controller: GlobeController? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do { return GlobeController(geo: try GeoData(device: device)) } catch {
            NSLog("Shanhai geo load failed: \(error)")
            return nil
        }
    }()

    var body: some Scene {
        WindowGroup {
            if let controller {
                ContentView(controller: controller)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                Text("地理数据加载失败").padding(40)
            }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            if let c = controller {
                CommandMenu("地图") {
                    Button("普通") { c.mode = .political }.keyboardShortcut("1")
                    Button("地形") { c.mode = .terrain }.keyboardShortcut("2")
                    Button("复古") { c.mode = .vintage }.keyboardShortcut("3")
                    Button("黑金") { c.mode = .blackgold }.keyboardShortcut("4")
                    Divider()
                    Button("搜索…") { c.searchRequest += 1 }.keyboardShortcut("f")
                    Button("回到整个地球") { c.home() }.keyboardShortcut("0")
                    Button("3D 视角") { c.toggle3D() }.keyboardShortcut("d")
                    Button(c.climateOn ? "关闭季风" : "季风") { c.toggleClimate() }.keyboardShortcut("j")
                    Button("放大") { c.zoomAnimated(0.5) }.keyboardShortcut("=")
                    Button("缩小") { c.zoomAnimated(2) }.keyboardShortcut("-")
                    Divider()
                    Button("关闭介绍") { c.clearSelection() }.keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
