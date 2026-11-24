import Foundation
import simd
import CoreGraphics

/// 차량 좌표계: X = 오른쪽, Z = 앞쪽, 원점 = 카메라 바로 아래 노면.
/// 월드 좌표계: ARKit (y 위, 중력 정렬).
struct CarPose {
    var origin = SIMD3<Float>(0, 0, 0)   // 월드, 노면 높이
    var forward = SIMD3<Float>(0, 0, -1) // 월드, 수평 단위벡터
    var right: SIMD3<Float> { SIMD3(-forward.z, 0, forward.x) }

    func toWorld(_ x: Float, _ z: Float, y: Float = 0) -> SIMD3<Float> {
        origin + right * x + forward * z + SIMD3(0, y, 0)
    }
    /// 월드 → 차량 (X, Z)
    func toCar(_ p: SIMD3<Float>) -> SIMD2<Float> {
        let d = p - origin
        return SIMD2(simd_dot(d, right), simd_dot(d, forward))
    }
    func toCarDir(_ v: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(simd_dot(v, right), simd_dot(v, forward))
    }
}

/// 렌더러·검출기가 공유하는 프레임 정보 (ARFrame 을 오래 붙잡지 않도록 값만 복사)
struct CameraSnap {
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    var imageSize: SIMD2<Float>
    /// 이미지 정규좌표 → 세로 화면 정규좌표 (좌상단 원점)
    var toPortrait: CGAffineTransform
    var fromPortrait: CGAffineTransform
    var groundY: Float
    var time: Float

    var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }

    /// 세로 화면 정규좌표의 한 점을 노면(groundY)에 투영 → 월드 좌표
    func groundHit(portrait p: CGPoint, maxDistance: Float = 80) -> SIMD3<Float>? {
        let img = p.applying(fromPortrait)
        let u = Float(img.x) * imageSize.x
        let v = Float(img.y) * imageSize.y
        let fx = intrinsics.columns.0.x, fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x, cy = intrinsics.columns.2.y
        let dirCam = SIMD4<Float>((u - cx) / fx, -(v - cy) / fy, -1, 0)
        let d4 = transform * dirCam
        let dir = SIMD3<Float>(d4.x, d4.y, d4.z)
        guard dir.y < -0.005 else { return nil }
        let t = (groundY - position.y) / dir.y
        guard t > 0 else { return nil }
        let hit = position + dir * t
        let flat = SIMD2<Float>(hit.x - position.x, hit.z - position.z)
        guard simd_length(flat) < maxDistance else { return nil }
        return hit
    }
}

enum M4 {
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)))
    }

    static func ortho(l: Float, r: Float, b: Float, t: Float, n: Float, f: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 / (r - l), 0, 0, 0),
            SIMD4(0, 2 / (t - b), 0, 0),
            SIMD4(0, 0, 1 / (n - f), 0),
            SIMD4((l + r) / (l - r), (t + b) / (b - t), n / (n - f), 1)))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}

/// 가상 카메라. 내부 좌표는 GL 식 차량 좌표 (x = X, y = 위, z = -Z).
struct VirtualCamera {
    enum Kind: String, CaseIterable, Identifiable {
        case top, chase
        var id: String { rawValue }
        var label: String { self == .top ? "위에서" : "뒤에서" }
    }

    var kind: Kind
    var aspect: Float   // 너비 / 높이
    var zoom: Float = 1 // 1 = 기본

    var eye: SIMD3<Float> {
        switch kind {
        case .top: return SIMD3(0, 60, -3)
        case .chase: return SIMD3(0, 7.5 / zoom, 10 / zoom)
        }
    }

    // 3D 오버레이(SceneKit)도 같은 값으로 카메라를 맞춘다
    var center: SIMD3<Float> { kind == .top ? SIMD3(0, 0, -3) : SIMD3(0, 0, -9) }
    var up: SIMD3<Float> { kind == .top ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0) }
    static let fovyDeg: Float = 55
    var orthoHalfHeight: Float { 15 / zoom }
    static let near: Float = 0.5, far: Float = 300

    var viewProj: simd_float4x4 {
        let view = M4.lookAt(eye: eye, center: center, up: up)
        switch kind {
        case .top:
            let halfH = orthoHalfHeight
            let halfW = halfH * aspect
            return M4.ortho(l: -halfW, r: halfW, b: -halfH, t: halfH, n: 1, f: 200) * view
        case .chase:
            return M4.perspective(fovy: VirtualCamera.fovyDeg * .pi / 180, aspect: aspect,
                                  near: VirtualCamera.near, far: VirtualCamera.far) * view
        }
    }

    /// 차량 좌표 (X, 높이, Z) → 화면 점. 카메라 뒤면 nil.
    func project(_ X: Float, _ y: Float, _ Z: Float, size: CGSize, vp: simd_float4x4) -> CGPoint? {
        let c = vp * SIMD4<Float>(X, y, -Z, 1)
        guard c.w > 0.2 else { return nil }
        let nx = c.x / c.w, ny = c.y / c.w
        return CGPoint(x: CGFloat((nx + 1) * 0.5) * size.width, y: CGFloat((1 - ny) * 0.5) * size.height)
    }
}
