import ARKit
import Combine
import simd

/// ARKit 세션 + 자차 자세 추정.
/// 폰은 차에 고정돼 있으므로 "차 방향 = 카메라 방위각 + 고정 오프셋".
/// 오프셋은 직진 주행 중 이동 방향으로 학습한다 (폰이 비뚤게 거치돼도 보정).
final class ARManager: NSObject, ObservableObject, ARSessionDelegate {
    static let shared = ARManager()

    let session = ARSession()
    private let queue = DispatchQueue(label: "ar.delegate", qos: .userInteractive)

    // UI 표시용 (메인)
    @Published var speedKmh: Double = 0
    @Published var trackingText = "시작 전"
    @Published var trackingOK = false
    @Published var headingLearned = false
    @Published var thermalText = ""

    // 렌더러/검출기용 최신 프레임 (lock 보호)
    private let lock = NSLock()
    private var _pixelBuffer: CVPixelBuffer?
    private var _snap: CameraSnap?
    private var _pose = CarPose()
    private var _frameID: UInt64 = 0
    private var _resetID: UInt64 = 0

    // 자세 추정 상태 (ar 큐 전용)
    private var t0: TimeInterval?
    private var history: [(t: Double, p: SIMD3<Float>, yaw: Float)] = []
    private var offsetVec = SIMD2<Float>(1, 0) // (cos, sin)
    private var offsetSamples = 0
    private var lastPublish: Double = 0
    private var cachedImageSize = CGSize.zero
    private var cachedToPortrait = CGAffineTransform.identity
    private var cachedFromPortrait = CGAffineTransform.identity

    var onFrame: ((CVPixelBuffer, CameraSnap, CarPose) -> Void)?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func latest() -> (CVPixelBuffer, CameraSnap, CarPose, UInt64, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let pb = _pixelBuffer, let s = _snap else { return nil }
        return (pb, s, _pose, _frameID, _resetID)
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingText = "이 기기는 ARKit 위치 추적을 지원하지 않습니다"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.isAutoFocusEnabled = true
        if let fmt = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.framesPerSecond == 30 && $0.imageResolution.width == 1920 && $0.imageResolution.height == 1440
        }) {
            config.videoFormat = fmt
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func pause() {
        session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 노면 기억·물체·방향 학습을 모두 지우고 추적을 다시 시작
    func reset(keepHeading: Bool = true) {
        Recorder.shared.event("reset", ["keepHeading": keepHeading])
        queue.async {
            self.history.removeAll()
            self.t0 = nil
            if !keepHeading { self.offsetVec = SIMD2(1, 0); self.offsetSamples = 0 }
            self.lock.lock(); self._resetID &+= 1; self._pixelBuffer = nil; self._snap = nil; self.lock.unlock()
            DispatchQueue.main.async { self.start() }
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if t0 == nil { t0 = frame.timestamp }
        let t = frame.timestamp
        let time = Float(t - (t0 ?? t))
        let cam = frame.camera
        let tf = cam.transform
        let pos = SIMD3<Float>(tf.columns.3.x, tf.columns.3.y, tf.columns.3.z)

        // 세로 화면 ↔ 이미지 정규좌표 변환 (해상도가 같으면 재사용)
        let res = cam.imageResolution
        if res != cachedImageSize {
            cachedImageSize = res
            let portrait = CGSize(width: res.height, height: res.width)
            cachedToPortrait = frame.displayTransform(for: .portrait, viewportSize: portrait)
            cachedFromPortrait = cachedToPortrait.inverted()
        }

        // 카메라 광축의 수평 방위
        let look = -SIMD3<Float>(tf.columns.2.x, tf.columns.2.y, tf.columns.2.z)
        let lookH = SIMD2<Float>(look.x, look.z)
        var camYaw: Float = history.last?.yaw ?? 0
        if simd_length(lookH) > 0.15 { camYaw = atan2f(lookH.y, lookH.x) }

        let ok: Bool
        switch cam.trackingState {
        case .normal: ok = true
        default: ok = false
        }

        history.append((t, pos, camYaw))
        history.removeAll { t - $0.t > 0.6 }

        // 속도 (0.5초 창)
        var vel = SIMD2<Float>(0, 0)
        if let first = history.first, t - first.t > 0.25 {
            let dt = Float(t - first.t)
            vel = SIMD2((pos.x - first.p.x) / dt, (pos.z - first.p.z) / dt)
        }
        let speed = simd_length(vel)

        // 방향 오프셋 학습: 직진(방위 변화 작음) + 충분한 속도
        var offsetAngle = atan2f(offsetVec.y, offsetVec.x)
        if ok, speed > 2.5, let first = history.first {
            let yawRate = abs(angleDiff(camYaw, first.yaw)) / Float(max(t - first.t, 0.01))
            if yawRate < 0.06 { // 약 3.4°/s 미만
                var moveAngle = atan2f(vel.y, vel.x)
                let curHeading = camYaw + offsetAngle
                // 후진이면 반대 방향
                if offsetSamples > 0, cosf(angleDiff(moveAngle, curHeading)) < 0 { moveAngle += .pi }
                let est = angleDiff(moveAngle, camYaw)
                let estVec = SIMD2<Float>(cosf(est), sinf(est))
                let alpha: Float = offsetSamples == 0 ? 1 : 0.03
                offsetVec = simd_normalize(offsetVec * (1 - alpha) + estVec * alpha)
                offsetSamples += 1
                offsetAngle = atan2f(offsetVec.y, offsetVec.x)
            }
        }

        let heading = camYaw + offsetAngle
        let mount = Prefs.f(Prefs.mountHeight)
        let groundY = pos.y - mount
        var pose = CarPose()
        pose.origin = SIMD3(pos.x, groundY, pos.z)
        pose.forward = SIMD3(cosf(heading), 0, sinf(heading))

        let snap = CameraSnap(transform: tf, intrinsics: cam.intrinsics,
                              imageSize: SIMD2(Float(res.width), Float(res.height)),
                              toPortrait: cachedToPortrait, fromPortrait: cachedFromPortrait,
                              groundY: groundY, time: time, stamp: t)

        lock.lock()
        if ok { // 추적이 불안정하면 노면을 기록하지 않음 (이전 정상 프레임 유지)
            _pixelBuffer = frame.capturedImage
            _snap = snap
            _pose = pose
            _frameID &+= 1
        }
        lock.unlock()

        if ok { onFrame?(frame.capturedImage, snap, pose) }

        if Recorder.shared.active {
            let signedSpeed = simd_dot(SIMD3(vel.x, 0, vel.y), pose.forward) >= 0 ? speed : -speed
            Recorder.shared.record(frame: frame, pose: pose, speed: signedSpeed, offsetAngle: offsetAngle,
                                   offsetSamples: offsetSamples, ok: ok)
        }

        if t - lastPublish > 0.2 {
            lastPublish = t
            let signed = simd_dot(SIMD3(vel.x, 0, vel.y), pose.forward) >= 0 ? speed : -speed
            let text = Self.describe(cam.trackingState)
            let learned = offsetSamples > 30
            let thermal = Self.thermal()
            DispatchQueue.main.async {
                self.speedKmh = Double(signed) * 3.6
                self.trackingText = text
                self.trackingOK = ok
                self.headingLearned = learned
                self.thermalText = thermal
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Recorder.shared.event("ar_error", ["msg": error.localizedDescription])
        DispatchQueue.main.async { self.trackingText = "오류: \(error.localizedDescription)" }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Recorder.shared.event("interrupted")
        DispatchQueue.main.async { self.trackingText = "중단됨" }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Recorder.shared.event("interruption_ended")
        reset()
    }

    private static func describe(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "추적 정상"
        case .notAvailable: return "추적 불가"
        case .limited(let r):
            switch r {
            case .initializing: return "초기화 중"
            case .excessiveMotion: return "흔들림 과다"
            case .insufficientFeatures: return "특징점 부족"
            case .relocalizing: return "위치 재확인 중"
            @unknown default: return "추적 제한"
            }
        }
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return ""
        case .fair: return "온도 약간 높음"
        case .serious: return "온도 높음 · 인식 속도 낮춤"
        case .critical: return "과열 · 잠시 꺼 주세요"
        @unknown default: return ""
        }
    }
}

func angleDiff(_ a: Float, _ b: Float) -> Float {
    var d = a - b
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return d
}
