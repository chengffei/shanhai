import AppKit
import MetalKit
import Observation

enum MapMode: String, CaseIterable { case political, terrain }

/// 地球的状态：相机、选中、悬停、模式。视图和面板都看它。
@Observable
final class GlobeController {
    let geo: GeoData
    var camera = Camera() { didSet { if camera != oldValue { requestRedraw() } } }
    var mode: MapMode = .political { didSet { requestRedraw() } }
    var selectedRegion = 0 { didSet { requestRedraw() } }
    var selectedCountry = 0 { didSet { requestRedraw() } }
    var hoverRegion = 0
    var hoverCountry = 0

    @ObservationIgnored weak var view: MTKView?
    @ObservationIgnored weak var renderer: GlobeRenderer?
    @ObservationIgnored private var flight: Flight?
    @ObservationIgnored private var velocity = SIMD2<Double>.zero    // 惯性：度/秒
    @ObservationIgnored private var lastStep = CACurrentMediaTime()

    init(geo: GeoData) { self.geo = geo }

    func requestRedraw() {
        guard let view else { return }
        view.needsDisplay = true
    }

    private var animating = false {
        didSet {
            guard animating != oldValue, let view else { return }
            view.isPaused = !animating
            lastStep = CACurrentMediaTime()
        }
    }

    // MARK: 选中

    /// 全球视角看不到省界，只选国家；放大到省级才选省
    func select(lat: Double, lon: Double) {
        let hit = geo.lookup(lat: lat, lon: lon)
        selectedRegion = camera.showsProvinces ? hit.region : 0
        selectedCountry = hit.country
    }

    func select(region id: Int, animate: Bool = true) {
        guard let r = geo.region(id) else { return }
        selectedRegion = id
        selectedCountry = r.country
        if animate { fly(to: r.label[1], lon: r.label[0], extentDeg: max(r.bbox[2] - r.bbox[0], r.bbox[3] - r.bbox[1])) }
    }

    func select(country id: Int, animate: Bool = true) {
        guard let c = geo.country(id) else { return }
        selectedRegion = 0
        selectedCountry = id
        if animate { fly(to: c.label[1], lon: c.label[0], extentDeg: min(60, max(c.bbox[2] - c.bbox[0], c.bbox[3] - c.bbox[1]))) }
    }

    func clearSelection() { selectedRegion = 0; selectedCountry = 0 }

    func hover(lat: Double?, lon: Double?) {
        var r = 0, c = 0
        if let lat, let lon {
            (r, c) = geo.lookup(lat: lat, lon: lon)
            if !camera.showsProvinces { r = 0 }
        }
        if r != hoverRegion || c != hoverCountry {
            hoverRegion = r; hoverCountry = c
            requestRedraw()
        }
    }

    // MARK: 相机动画

    struct Flight {
        let from: Camera, to: Camera
        let start: CFTimeInterval, duration: CFTimeInterval
        let peak: Double
    }

    func fly(to lat: Double, lon: Double, extentDeg: Double) {
        var to = camera
        to.lat = lat; to.lon = lon
        to.tilt = 0; to.heading = 0
        to.altitude = max(Camera.minAltitude, min(3.2, extentDeg * .pi / 180 / (2 * tan(Camera.fovY / 2)) * 1.6))
        let dLon = remainder(lon - camera.lon, 360), dLat = lat - camera.lat
        let arc = (dLon * dLon + dLat * dLat).squareRoot() * .pi / 180
        let peak = max(camera.altitude, to.altitude, min(3.0, arc * 0.9))
        var target = to
        target.lon = camera.lon + dLon     // 走短的那边
        flight = Flight(from: camera, to: target, start: CACurrentMediaTime(), duration: 0.9 + min(1.0, arc * 0.35), peak: peak)
        velocity = .zero
        animating = true
    }

    /// 直接飞到给定相机（不抬高中途高度）
    func animate(to target: Camera, duration: Double = 0.6) {
        var t = target
        t.clamp()
        t.lon = camera.lon + remainder(t.lon - camera.lon, 360)
        flight = Flight(from: camera, to: t, start: CACurrentMediaTime(), duration: duration, peak: max(camera.altitude, t.altitude))
        velocity = .zero
        animating = true
    }

    func home() {
        var c = camera
        c.altitude = 3.2; c.tilt = 0; c.heading = 0
        animate(to: c, duration: 1.0)
    }

    func toggle3D() {
        var c = camera
        c.tilt = c.tilt > 0.05 ? 0 : min(c.maxTilt, 1.0)
        animate(to: c)
    }

    func northUp() {
        var c = camera
        c.heading = 0
        animate(to: c, duration: 0.4)
    }

    func zoomAnimated(_ factor: Double) {
        var c = camera
        c.altitude *= factor
        c.clamp()
        animate(to: c, duration: 0.35)
    }

    func stopMotion() { flight = nil; velocity = .zero; animating = false }

    func fling(_ v: SIMD2<Double>) {
        guard simd_length(v) > 2 else { return }
        velocity = v
        animating = true
    }

    /// 每帧由渲染器调用
    func stepAnimation() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastStep)
        lastStep = now
        if let f = flight {
            let t = min(1, (now - f.start) / f.duration)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            var c = f.to
            c.lat = f.from.lat + (f.to.lat - f.from.lat) * e
            c.lon = f.from.lon + (f.to.lon - f.from.lon) * e
            c.tilt = f.from.tilt + (f.to.tilt - f.from.tilt) * e
            c.heading = f.from.heading + remainder(f.to.heading - f.from.heading, 2 * .pi) * e
            // 高度按对数插值，中途抬到 peak
            let la = log(f.from.altitude), lb = log(f.to.altitude), lp = log(f.peak)
            let base = la + (lb - la) * e
            let lift = (lp - max(la, lb)) * sin(.pi * t)
            c.altitude = exp(base + max(0, lift))
            c.clamp()
            camera = c
            if t >= 1 { flight = nil }
        } else if simd_length(velocity) > 0.5 {
            var c = camera
            c.lat += velocity.y * dt
            c.lon += velocity.x * dt / max(0.2, cos(c.lat * .pi / 180))
            c.clamp()
            camera = c
            velocity *= pow(0.02, dt)     // 约 1 秒内衰减
        } else {
            velocity = .zero
        }
        if flight == nil && velocity == .zero && animating {
            DispatchQueue.main.async { self.animating = false }
        }
    }

    // MARK: 手势

    /// 屏幕位移（点，右为正、上为正）→ 平移
    func pan(dx: Double, dy: Double, viewHeight: Double) {
        let k = camera.degreesPerPixel(viewHeight: viewHeight)
        let h = camera.heading
        let north = (dx * sin(h) - dy * cos(h)) * k
        let east = (-dx * cos(h) - dy * sin(h)) * k
        var c = camera
        c.lat += north
        c.lon += east / max(0.2, cos(c.lat * .pi / 180))
        c.clamp()
        camera = c
    }

    func zoom(factor: Double) {
        var c = camera
        c.altitude *= factor
        c.clamp()
        camera = c
    }

    func orbit(dTilt: Double, dHeading: Double) {
        var c = camera
        c.tilt += dTilt
        c.heading += dHeading
        c.clamp()
        camera = c
    }
}
