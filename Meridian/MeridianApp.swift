import SwiftUI

@main
struct MeridianApp: App {
    @State private var controller: GlobeController? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do { return GlobeController(geo: try GeoData(device: device)) } catch {
            NSLog("Meridian geo load failed: \(error)")
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
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
