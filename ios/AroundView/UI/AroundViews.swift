import SwiftUI
import MetalKit
import simd

/// 렌더 스레드 → SwiftUI 오버레이로 마지막 자세 전달
final class PoseHolder {
    static let shared = PoseHolder()
    private let lock = NSLock()
    private var pose = CarPose()
    private var time: Float = 0
    func set(_ p: CarPose, _ t: Float) { lock.lock(); pose = p; time = t; lock.unlock() }
    func get() -> (CarPose, Float) { lock.lock(); defer { lock.unlock() }; return (pose, time) }
}

struct AroundMetalView: UIViewRepresentable {
    var kind: VirtualCamera.Kind
    var mode: Int
    var zoom: Float

    func makeCoordinator() -> Holder { Holder() }
    final class Holder { var renderer: AroundRenderer? }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: GroundMemory.shared.device)
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 30
        v.isOpaque = true
        let r = AroundRenderer(view: v)
        r.onPose = { PoseHolder.shared.set($0, $1) }
        context.coordinator.renderer = r
        v.delegate = r
        update(r)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        if let r = context.coordinator.renderer { update(r) }
    }

    private func update(_ r: AroundRenderer) {
        r.viewKind = kind; r.mode = mode; r.zoom = zoom
    }
}

struct CameraPreviewView: UIViewRepresentable {
    func makeCoordinator() -> Holder { Holder() }
    final class Holder { var renderer: PreviewRenderer? }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: GroundMemory.shared.device)
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 15
        let r = PreviewRenderer(view: v)
        context.coordinator.renderer = r
        v.delegate = r
        return v
    }
    func updateUIView(_ v: MTKView, context: Context) {}
}

/// 자차·주변 물체를 3D 상자로 그리는 오버레이 (Metal 노면과 같은 가상 카메라 사용)
struct ObjectOverlay: View {
    var kind: VirtualCamera.Kind
    var zoom: Float
    @ObservedObject var detector = ObjectDetector.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { ctx, size in
                let (pose, now) = PoseHolder.shared.get()
                let cam = VirtualCamera(kind: kind, aspect: Float(size.width / max(size.height, 1)), zoom: zoom)
                let vp = cam.viewProj
                var boxes: [Box3] = []

                // 자차
                let front = Prefs.f(Prefs.carFront), rear = Prefs.f(Prefs.carRear), width = Prefs.f(Prefs.carWidth)
                boxes.append(Box3(cx: 0, cz: (front - rear) / 2, dx: 0, dz: 1, w: width, l: front + rear, h: 1.45,
                                  color: Color(red: 0.92, green: 0.94, blue: 0.98), alpha: 1, ego: true))

                for o in detector.objects {
                    let p = o.predicted(at: now)
                    let c = pose.toCar(SIMD3(p.x, pose.origin.y, p.y))
                    let d = pose.toCarDir(SIMD3(o.heading.x, 0, o.heading.y))
                    let len = max(simd_length(d), 0.001)
                    let unseen = now - o.lastSeen
                    let alpha = Double(unseen < 0.5 ? 1 : max(0.25, 1 - (unseen - 0.5) / 5))
                    let s = o.kind.size
                    let col: Color = o.kind == .person ? Color(red: 1, green: 0.62, blue: 0.2)
                        : (o.kind.isVehicle ? Color(red: 0.62, green: 0.66, blue: 0.72) : Color(red: 0.4, green: 0.8, blue: 1))
                    boxes.append(Box3(cx: c.x, cz: c.y, dx: d.x / len, dz: d.y / len,
                                      w: o.kind.isVehicle ? o.width : s.w, l: s.l, h: s.h, color: col, alpha: alpha, ego: false))
                }

                let eye = cam.eye
                boxes.sort { $0.distance(to: eye) > $1.distance(to: eye) }
                for b in boxes { b.draw(ctx: &ctx, size: size, cam: cam, vp: vp, eye: eye) }
            }
        }
        .allowsHitTesting(false)
    }
}

struct Box3 {
    var cx, cz, dx, dz, w, l, h: Float
    var color: Color
    var alpha: Double
    var ego: Bool

    func distance(to eye: SIMD3<Float>) -> Float {
        simd_distance(SIMD3(cx, h / 2, -cz), eye)
    }

    func draw(ctx: inout GraphicsContext, size: CGSize, cam: VirtualCamera, vp: simd_float4x4, eye: SIMD3<Float>) {
        let px = dz, pz = -dx // 길이축에 수직
        let hl = l / 2, hw = w / 2
        let foot: [SIMD2<Float>] = [
            SIMD2(cx + dx * hl + px * hw, cz + dz * hl + pz * hw),
            SIMD2(cx + dx * hl - px * hw, cz + dz * hl - pz * hw),
            SIMD2(cx - dx * hl - px * hw, cz - dz * hl - pz * hw),
            SIMD2(cx - dx * hl + px * hw, cz - dz * hl + pz * hw),
        ]
        var bottom: [CGPoint] = [], top: [CGPoint] = []
        for f in foot {
            guard let b = cam.project(f.x, 0, f.y, size: size, vp: vp),
                  let t = cam.project(f.x, h, f.y, size: size, vp: vp) else { return }
            bottom.append(b); top.append(t)
        }
        // 그림자
        ctx.fill(poly(bottom), with: .color(.black.opacity(0.35 * alpha)))

        // 옆면: 먼 면부터
        var faces: [(Float, [CGPoint], Double)] = []
        for i in 0..<4 {
            let j = (i + 1) % 4
            let mid = (foot[i] + foot[j]) / 2
            let dist = simd_distance(SIMD3(mid.x, h / 2, -mid.y), eye)
            let edge = foot[j] - foot[i]
            let normal = simd_normalize(SIMD2(edge.y, -edge.x))
            let shade = 0.55 + 0.3 * Double(abs(normal.x))
            faces.append((dist, [bottom[i], bottom[j], top[j], top[i]], shade))
        }
        faces.sort { $0.0 > $1.0 }
        for f in faces {
            ctx.fill(poly(f.1), with: .color(color.opacity(alpha).mix(.black, f.2)))
        }
        let topPath = poly(top)
        ctx.fill(topPath, with: .color(color.opacity(alpha)))
        if ego {
            ctx.stroke(topPath, with: .color(Color(red: 0.25, green: 0.6, blue: 1)), lineWidth: 2)
            // 앞유리 표시
            let fx = cx, fz = cz + hl * 0.45
            if let a = cam.project(fx - hw * 0.8, h, fz, size: size, vp: vp),
               let b = cam.project(fx + hw * 0.8, h, fz, size: size, vp: vp) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(Color(red: 0.25, green: 0.6, blue: 1)), lineWidth: 3)
            }
        } else {
            ctx.stroke(topPath, with: .color(.white.opacity(0.5 * alpha)), lineWidth: 1)
        }
    }

    private func poly(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }
}

private extension Color {
    /// 어둡게: k = 1 원색, 0 검정
    func mix(_ other: Color, _ k: Double) -> Color {
        let u = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: r * k, green: g * k, blue: b * k).opacity(a)
    }
}
