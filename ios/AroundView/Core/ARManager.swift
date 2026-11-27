import ARKit
import Combine
import simd

/// ARKit 세션 + 자차 자세 추정.
/// 폰은 차에 고정돼 있고 카메라가 앞을 보므로 "차 방향 = 카메라 방위각 + 거치 비뚤어짐(±45°)".
/// 전진·후진·흔들림 걸러내기·GPS 검증은 PoseFilter 참고.
final class ARManager: NSObject, ObservableObject, ARSessionDelegate {
    static let shared = ARManager()

    let session = ARSession()
    private let queue = DispatchQueue(label: "ar.delegate", qos: .userInteractive)

    // UI 표시용 (메인)
    @Published var speedKmh: Double = 0
    @Published var trackingText = "시작 전"
    @Published var trackingOK = false
    @Published var headingLearned = false
    @Published var skipText = ""   // 노면 기록을 쉬는 이유 (흔들림 등)
    @Published var thermalText = ""

    // 렌더러/검출기용 최신 프레임 (lock 보호)
    private let lock = NSLock()
    private var _pixelBuffer: CVPixelBuffer?
    private var _snap: CameraSnap?
    private var _pose = CarPose()
    private var _frameID: UInt64 = 0
    private var _resetID: UInt64 = 0

    // 자세 추정 (ar 큐 전용) — 계산은 PoseFilter
    private var t0: TimeInterval?
    private let filter = PoseFilter()
    private var _writeID: UInt64 = 0
    private var lastPublish: Double = 0
    private var cachedImageSize = CGSize.zero
    private var cachedToPortrait = CGAffineTransform.identity
    private var cachedFromPortrait = CGAffineTransform.identity

    var onFrame: ((CVPixelBuffer, CameraSnap, CarPose) -> Void)?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
        SensorHub.shared.onForwardAccel = { [weak self] t, a in
            guard let self else { return }
            self.queue.async { self.filter.accel(t: t, forward: a) }
        }
        SensorHub.shared.onGPS = { [weak self] t, spd, acc in
            guard let self else { return }
            self.queue.async { self.filter.gps(t: t, speed: spd, speedAccuracy: acc) }
        }
    }

    /// 반환의 네 번째 값은 "노면 기억에 써도 되는 프레임" 번호 — 흔들림·추적 이상 프레임에서는 늘지 않는다
    func latest() -> (CVPixelBuffer, CameraSnap, CarPose, UInt64, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let pb = _pixelBuffer, let s = _snap else { return nil }
        return (pb, s, _pose, _writeID, _resetID)
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
        SensorHub.shared.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func pause() {
        session.pause()
        if !Recorder.shared.isRecording { SensorHub.shared.stop() }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 노면 기억·물체·방향 학습을 모두 지우고 추적을 다시 시작
    func reset(keepHeading: Bool = true) {
        Recorder.shared.event("reset", ["keepHeading": keepHeading])
        queue.async {
            self.filter.reset(keepOffset: keepHeading)
            self.t0 = nil
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

        let look = -SIMD3<Float>(tf.columns.2.x, tf.columns.2.y, tf.columns.2.z)
        let ok: Bool
        switch cam.trackingState {
        case .normal: ok = true
        default: ok = false
        }

        filter.mountHeight = Prefs.f(Prefs.mountHeight)
        let o = filter.frame(t: t, pos: pos, look: look, ok: ok)
        var pose = CarPose()
        pose.origin = o.origin
        pose.forward = SIMD3(o.forward.x, 0, o.forward.y)
        let groundY = o.groundY

        let snap = CameraSnap(transform: tf, intrinsics: cam.intrinsics,
                              imageSize: SIMD2(Float(res.width), Float(res.height)),
                              toPortrait: cachedToPortrait, fromPortrait: cachedFromPortrait,
                              groundY: groundY, time: time, stamp: t)

        lock.lock()
        if ok { // 추적이 불안정하면 이전 정상 프레임 유지
            _pose = pose
            _frameID &+= 1
            // 흔들림·GPS 불일치 프레임은 노면에 쓰지 않음 → 기록용 영상·자세는 마지막 좋은 프레임으로 둔다
            if o.writeGround || _snap == nil {
                _pixelBuffer = frame.capturedImage
                _snap = snap
                _writeID &+= 1
            }
        }
        lock.unlock()

        if ok { onFrame?(frame.capturedImage, snap, pose) }

        if Recorder.shared.active {
            Recorder.shared.record(frame: frame, pose: pose, speed: o.speed, offsetAngle: o.offset,
                                   offsetSamples: o.offsetSamples, ok: ok,
                                   write: o.writeGround, skipReason: o.reason, groundY: groundY)
        }

        if t - lastPublish > 0.2 {
            lastPublish = t
            let signed = o.speed
            let text = Self.describe(cam.trackingState)
            let learned = o.offsetSamples > 30
            let skip = ok ? o.reason : ""
            let thermal = Self.thermal()
            DispatchQueue.main.async {
                self.speedKmh = Double(signed) * 3.6
                self.trackingText = text
                self.trackingOK = ok
                self.headingLearned = learned
                self.thermalText = thermal
                self.skipText = skip
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
