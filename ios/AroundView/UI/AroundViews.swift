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
