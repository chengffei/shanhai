import Foundation
import simd

/// 环绕相机：盯住地表一点，从上方一定高度看下去，可倾斜、旋转。长度单位为地球半径。
struct Camera: Equatable {
    var lat: Double = 30          // 度
    var lon: Double = 110
    var altitude: Double = 3.2    // 视点到目标点的距离
    var tilt: Double = 0          // 弧度，0 = 垂直俯视
    var heading: Double = 0       // 弧度，0 = 北朝上

    static let minAltitude = 0.035
    static let maxAltitude = 6.0
    static let fovY = 35.0 * Double.pi / 180

    /// 高度越低允许倾斜越大
    var maxTilt: Double {
        let t = (log(Camera.maxAltitude / 2) - log(altitude)) / (log(Camera.maxAltitude / 2) - log(Camera.minAltitude))
        return max(0, min(1, t)) * 1.15
    }

    mutating func clamp() {
        altitude = min(Camera.maxAltitude, max(Camera.minAltitude, altitude))
        lat = min(85, max(-85, lat))
        lon = remainder(lon, 360)
        tilt = min(maxTilt, max(0, tilt))
    }

    struct Frame {
        let eye: SIMD3<Double>, target: SIMD3<Double>, up: SIMD3<Double>
        let normal: SIMD3<Double>, east: SIMD3<Double>, north: SIMD3<Double>
    }

    var frame: Frame {
        let la = lat * .pi / 180, lo = lon * .pi / 180
        let n = SIMD3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
        let east = SIMD3(cos(lo), 0, -sin(lo))
        let north = simd_cross(n, east)
        let fwd = north * cos(heading) + east * sin(heading)
        let eye = n + (n * cos(tilt) - fwd * sin(tilt)) * altitude
        let up = simd_normalize(fwd * cos(tilt) + n * sin(tilt))
        return Frame(eye: eye, target: n, up: up, normal: n, east: east, north: north)
    }

    func matrices(aspect: Double) -> (view: simd_double4x4, proj: simd_double4x4) {
        let f = frame
        let near = max(altitude * 0.04, 1e-4)
        let far = simd_length(f.eye) + 1.2
        return (lookAt(eye: f.eye, target: f.target, up: f.up), perspective(fovY: Camera.fovY, aspect: aspect, near: near, far: far))
    }

    /// 屏幕上一单位像素对应的地表角度（度），用于拖拽
    func degreesPerPixel(viewHeight: Double) -> Double {
        let span = 2 * altitude * tan(Camera.fovY / 2)
        return min(span, 2.2) * 180 / .pi / viewHeight
    }
}

func lookAt(eye: SIMD3<Double>, target: SIMD3<Double>, up: SIMD3<Double>) -> simd_double4x4 {
    let z = simd_normalize(eye - target)
    let x = simd_normalize(simd_cross(up, z))
    let y = simd_cross(z, x)
    return simd_double4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
}

/// Metal 裁剪空间 z ∈ [0,1]
func perspective(fovY: Double, aspect: Double, near: Double, far: Double) -> simd_double4x4 {
    let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
    return simd_double4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
}

extension simd_double4x4 {
    var float: simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(columns.0), SIMD4<Float>(columns.1), SIMD4<Float>(columns.2), SIMD4<Float>(columns.3)))
    }
}

/// 射线与单位球求交，返回经纬度（度）
func pickLatLon(ndc: SIMD2<Double>, invViewProj: simd_double4x4, eye: SIMD3<Double>) -> (lat: Double, lon: Double)? {
    let a = invViewProj * SIMD4(ndc.x, ndc.y, 0, 1)
    let b = invViewProj * SIMD4(ndc.x, ndc.y, 1, 1)
    let p0 = SIMD3(a.x, a.y, a.z) / a.w, p1 = SIMD3(b.x, b.y, b.z) / b.w
    let d = simd_normalize(p1 - p0)
    let bq = simd_dot(eye, d), c = simd_dot(eye, eye) - 1
    let disc = bq * bq - c
    guard disc >= 0 else { return nil }
    let t = -bq - disc.squareRoot()
    guard t > 0 else { return nil }
    let p = simd_normalize(eye + d * t)
    return (asin(p.y) * 180 / .pi, atan2(p.x, p.z) * 180 / .pi)
}
