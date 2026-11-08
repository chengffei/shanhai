import SwiftUI
import MetalKit

struct GlobeView: NSViewRepresentable {
    let controller: GlobeController

    func makeNSView(context: Context) -> GlobeMTKView {
        let v = GlobeMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.controller = controller
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .invalid     // 深度与 MSAA 由渲染器自己建（memoryless）
        v.sampleCount = 1
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 1)
        v.preferredFramesPerSecond = 120
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        do {
            let r = try GlobeRenderer(view: v, geo: controller.geo)
            r.controller = controller
            v.renderer = r
            v.delegate = r
            controller.view = v
            controller.renderer = r
        } catch {
            NSLog("Shanhai renderer init failed: \(error)")
        }
        return v
    }

    func updateNSView(_ nsView: GlobeMTKView, context: Context) {}
}

final class GlobeMTKView: MTKView {
    weak var controller: GlobeController?
    var renderer: GlobeRenderer?
    private var downPoint: CGPoint?
    private var dragged = false
    private var lastDrag: (p: CGPoint, t: CFTimeInterval)?
    private var dragVelocity = SIMD2<Double>.zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// 视图坐标（点）→ 经纬度
    func latLon(at p: CGPoint) -> (lat: Double, lon: Double)? {
        guard let r = renderer, bounds.width > 0 else { return nil }
        let ndc = SIMD2(Double(p.x / bounds.width) * 2 - 1, Double(p.y / bounds.height) * 2 - 1)
        return pickLatLon(ndc: ndc, invViewProj: r.invViewProj, eye: r.eye)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.stopMotion()
        downPoint = convert(event.locationInWindow, from: nil)
        dragged = false
        lastDrag = (downPoint!, event.timestamp)
        dragVelocity = .zero
        if event.clickCount == 2, let ll = latLon(at: downPoint!), let c = controller {
            // 双击：放大到点击处
            c.fly(to: ll.lat, lon: ll.lon, extentDeg: c.camera.altitude * 0.45 * 2 * tan(Camera.fovY / 2) * 180 / .pi)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let d = downPoint, hypot(p.x - d.x, p.y - d.y) > 3 { dragged = true }
        guard dragged else { return }
        if event.modifierFlags.contains(.option) {
            c.orbit(dTilt: Double(event.deltaY) * 0.006, dHeading: Double(event.deltaX) * 0.006)
        } else {
            c.pan(dx: Double(event.deltaX), dy: -Double(event.deltaY), viewHeight: Double(bounds.height))
            if let last = lastDrag {
                let dt = max(1e-3, event.timestamp - last.t)
                let k = c.camera.degreesPerPixel(viewHeight: Double(bounds.height))
                let v = SIMD2(-Double(p.x - last.p.x) * k / dt, -Double(p.y - last.p.y) * k / dt)
                dragVelocity = dragVelocity * 0.5 + v * 0.5
            }
        }
        lastDrag = (p, event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragged {
            if event.clickCount == 1 {
                if let ll = latLon(at: p) { c.select(lat: ll.lat, lon: ll.lon) } else { c.clearSelection() }
            }
        } else if let last = lastDrag, event.timestamp - last.t < 0.08, !event.modifierFlags.contains(.option) {
            // 只按东西向的人眼直觉给惯性：x → 经度，y → 纬度（北为正）
            let h = c.camera.heading
            let v = dragVelocity
            c.fling(SIMD2(v.x * cos(h) + v.y * sin(h), v.y * cos(h) - v.x * sin(h)))
        }
        downPoint = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let ll = latLon(at: p)
        controller?.hover(lat: ll?.lat, lon: ll?.lon)
    }

    override func mouseExited(with event: NSEvent) { controller?.hover(lat: nil, lon: nil) }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return }
        c.stopMotion()
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // 触控板双指：平移，与「地图」一致
            c.pan(dx: Double(event.scrollingDeltaX), dy: -Double(event.scrollingDeltaY), viewHeight: Double(bounds.height))
        } else {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            c.zoom(factor: exp(-Double(d)))
        }
    }

    override func magnify(with event: NSEvent) {
        controller?.stopMotion()
        controller?.zoom(factor: exp(-Double(event.magnification) * 1.6))
    }

    override func rotate(with event: NSEvent) {
        controller?.orbit(dTilt: 0, dHeading: -Double(event.rotation) * .pi / 180)
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        let step = 40.0
        switch event.keyCode {
        case 123: c.pan(dx: step, dy: 0, viewHeight: Double(bounds.height))
        case 124: c.pan(dx: -step, dy: 0, viewHeight: Double(bounds.height))
        case 125: c.pan(dx: 0, dy: step, viewHeight: Double(bounds.height))
        case 126: c.pan(dx: 0, dy: -step, viewHeight: Double(bounds.height))
        case 24, 69: c.zoom(factor: 0.8)
        case 27, 78: c.zoom(factor: 1.25)
        case 53: c.clearSelection()
        default: super.keyDown(with: event)
        }
    }
}
