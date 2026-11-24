import Metal
import MetalKit
import CoreVideo
import simd

// Metal 셰이더와 같은 배치 (모두 16바이트 정렬 멤버)
struct WriteU {
    var worldToCam: simd_float4x4
    var intr: SIMD4<Float>
    var img: SIMD4<Float>
    var aff0: SIMD4<Float>
    var aff1: SIMD4<Float>
    var cam: SIMD4<Float>
    var grid: SIMD4<Float>
    var misc: SIMD4<Float>
}

struct RenderU {
    var invVP: simd_float4x4
    var car: SIMD4<Float>
    var grid: SIMD4<Float>
    var mode: SIMD4<Float>
}

struct PreviewU {
    var aff0: SIMD4<Float>
    var aff1: SIMD4<Float>
}

/// 공용 Metal 자원 + 노면 기억 텍스처 (월드 고정 격자, 원환 주소)
final class GroundMemory {
    static let shared = GroundMemory()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let writePipeline: MTLComputePipelineState
    var textureCache: CVMetalTextureCache?

    let N = 2048         // 격자 크기 (픽셀)
    let ppm: Float = 10  // 1m 당 픽셀 → 204.8m 범위
    private(set) var color: MTLTexture
    private(set) var meta: MTLTexture
    private var lastFrameID: UInt64 = 0
    private var lastResetID: UInt64 = 0
    private let lock = NSLock()

    init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        library = device.makeDefaultLibrary()!
        writePipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "writeGround")!)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        (color, meta) = GroundMemory.makeTextures(device: device, n: N)
        clear()
    }

    private static func makeTextures(device: MTLDevice, n: Int) -> (MTLTexture, MTLTexture) {
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: n, mipmapped: false)
        cd.usage = [.shaderRead, .shaderWrite]
        cd.storageMode = .private
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: n, height: n, mipmapped: false)
        md.usage = [.shaderRead, .shaderWrite]
        md.storageMode = .private
        let c = device.makeTexture(descriptor: cd)!
        let m = device.makeTexture(descriptor: md)!
        return (c, m)
    }

    /// 기억 지우기 (새 텍스처 = 모두 0 → meta 의 셀 번호가 맞지 않아 '기록 없음')
    func clear() {
        lock.lock(); defer { lock.unlock() }
        (color, meta) = GroundMemory.makeTextures(device: device, n: N)
        // private 텍스처는 0 으로 초기화된다는 보장이 없으므로 시간 -1e9 로 채운다
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder(),
              let fn = library.makeFunction(name: "clearMeta"),
              let ps = try? device.makeComputePipelineState(function: fn) else { return }
        enc.setComputePipelineState(ps)
        enc.setTexture(meta, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: N / 16, height: N / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
    }

    func cameraTextures(_ pb: CVPixelBuffer) -> (CVMetalTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        func make(_ plane: Int, _ fmt: MTLPixelFormat) -> CVMetalTexture? {
            let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
            var tex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &tex)
            return tex
        }
        guard let y = make(0, .r8Unorm), let c = make(1, .rg8Unorm) else { return nil }
        return (y, c)
    }

    /// 새 프레임이 있으면 노면 기억에 기록. 반환: 현재 자세 정보
    func update(commandBuffer cb: MTLCommandBuffer) -> (CarPose, CameraSnap, CVPixelBuffer)? {
        guard case let (pb, snap, pose, frameID, resetID)? = ARManager.shared.latest() else { return nil }
        if resetID != lastResetID {
            lastResetID = resetID
            clear()
            ObjectDetector.shared.clear()
            RoadMarkDetector.shared.clear()
        }
        guard frameID != lastFrameID else { return (pose, snap, pb) }
        lastFrameID = frameID

        guard case let (yT, cT)? = cameraTextures(pb),
              let yTex = CVMetalTextureGetTexture(yT), let cTex = CVMetalTextureGetTexture(cT),
              let enc = cb.makeComputeCommandEncoder() else { return (pose, snap, pb) }

        let maxDist = min(max(Prefs.f(Prefs.maxDistance), 8), 35)
        let cam = snap.position
        let originCell = SIMD2<Float>(floorf((cam.x - maxDist) * ppm), floorf((cam.z - maxDist) * ppm))
        let span = Int(ceilf(2 * maxDist * ppm)) + 1
        let k = snap.intrinsics
        let a = snap.toPortrait
        var boxes = ObjectDetector.shared.maskBoxes(now: snap.time).prefix(16).map {
            SIMD4<Float>($0.minX, $0.minY, $0.maxX, $0.maxY)
        }
        let boxCount = boxes.count
        if boxes.isEmpty { boxes = [SIMD4<Float>(0, 0, 0, 0)] }
        var u = WriteU(
            worldToCam: snap.transform.inverse,
            intr: SIMD4(k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y),
            img: SIMD4(snap.imageSize.x, snap.imageSize.y, snap.groundY, snap.time),
            aff0: SIMD4(Float(a.a), Float(a.c), Float(a.tx), 0),
            aff1: SIMD4(Float(a.b), Float(a.d), Float(a.ty), 0),
            cam: SIMD4(cam.x, cam.z, maxDist, min(max(Prefs.f(Prefs.hoodCut), 0), 0.8)),
            grid: SIMD4(originCell.x, originCell.y, ppm, Float(N)),
            misc: SIMD4(Float(boxCount), 0, 0, 0))

        lock.lock()
        enc.setComputePipelineState(writePipeline)
        enc.setTexture(color, index: 0)
        enc.setTexture(meta, index: 1)
        lock.unlock()
        enc.setTexture(yTex, index: 2)
        enc.setTexture(cTex, index: 3)
        enc.setBytes(&u, length: MemoryLayout<WriteU>.stride, index: 0)
        enc.setBytes(boxes, length: MemoryLayout<SIMD4<Float>>.stride * boxes.count, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (span + 15) / 16, height: (span + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.addCompletedHandler { _ in _ = (yT, cT) } // 텍스처 수명 유지
        return (pose, snap, pb)
    }

    func textures() -> (MTLTexture, MTLTexture) {
        lock.lock(); defer { lock.unlock() }
        return (color, meta)
    }
}

/// 어라운드 뷰 렌더러
final class AroundRenderer: NSObject, MTKViewDelegate {
    private let mem = GroundMemory.shared
    private let pipeline: MTLRenderPipelineState
    var viewKind: VirtualCamera.Kind = .chase
    var mode: Int = 2
    var zoom: Float = 1
    /// 화면 오버레이(SwiftUI)에서 쓰는 마지막 자세
    var onPose: ((CarPose, Float) -> Void)?

    init(view: MTKView) {
        let d = mem.library
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = d.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = d.makeFunction(name: "aroundFragment")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! mem.device.makeRenderPipelineState(descriptor: desc)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let cb = mem.queue.makeCommandBuffer() else { return }
        let state = mem.update(commandBuffer: cb)
        let size = view.drawableSize
        let cam = VirtualCamera(kind: viewKind, aspect: Float(size.width / max(size.height, 1)), zoom: zoom)
        let pose = state?.0 ?? CarPose()
        let time = state?.1.time ?? 0
        var u = RenderU(invVP: cam.viewProj.inverse,
                        car: SIMD4(pose.origin.x, pose.origin.z, pose.forward.x, pose.forward.z),
                        grid: SIMD4(mem.ppm, Float(mem.N), time, max(Prefs.f(Prefs.memorySec), 10)),
                        mode: SIMD4(Float(mode), 0, 0, 0))
        let (color, meta) = mem.textures()
        // 노면 표시 인식 (계산 인코더는 화면 인코더보다 먼저)
        if let state, mode != 0 {
            RoadMarkDetector.shared.maybeEncode(cb: cb, pose: state.0, time: state.1.time, color: color, meta: meta,
                                                grid: u.grid)
        }
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { cb.commit(); return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(color, index: 0)
        enc.setFragmentTexture(meta, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderU>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        if let state { onPose?(state.0, state.1.time) }
    }
}

/// 카메라 미리보기 (본넷 가림선 확인용)
final class PreviewRenderer: NSObject, MTKViewDelegate {
    private let mem = GroundMemory.shared
    private let pipeline: MTLRenderPipelineState

    init(view: MTKView) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = mem.library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = mem.library.makeFunction(name: "previewFragment")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! mem.device.makeRenderPipelineState(descriptor: desc)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard case let (pb, snap, _, _, _)? = ARManager.shared.latest(),
              case let (yT, cT)? = mem.cameraTextures(pb),
              let yTex = CVMetalTextureGetTexture(yT), let cTex = CVMetalTextureGetTexture(cT),
              let cb = mem.queue.makeCommandBuffer(),
              let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let a = snap.fromPortrait
        var u = PreviewU(aff0: SIMD4(Float(a.a), Float(a.c), Float(a.tx), 0),
                         aff1: SIMD4(Float(a.b), Float(a.d), Float(a.ty), 0))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PreviewU>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.addCompletedHandler { _ in _ = (yT, cT) }
        cb.present(drawable)
        cb.commit()
    }
}
