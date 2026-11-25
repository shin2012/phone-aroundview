import ARKit
import AVFoundation
import Combine
import CoreLocation
import CoreMotion
import UIKit
import VideoToolbox
import simd

/// 시험용 주행 기록. 서버에서 같은 계산을 다시 돌려 보기 위해 원자료를 모은다.
///
/// 기록 폴더 (Documents/Recordings/<yyyyMMdd_HHmmss>/):
/// - `video.mov`   카메라 원본 영상 (HEVC, 가로 1280×960, ARKit 프레임 시각 그대로, 5초 조각)
/// - `frames.jsonl` 프레임마다 카메라 자세·내부 파라미터·추적 상태·자차 자세·속도
/// - `motion.jsonl` 자이로·가속도·자세 (100Hz)
/// - `gps.jsonl`    위치·속도·방향 (GPS)
/// - `det.jsonl`    물체 인식 상자·노면 위치·추적 목록
/// - `marks.jsonl`  노면 표시 인식 결과
/// - `events.jsonl` 초기화·중단·발열·사용자 표시(문제 지점)
/// - `meta.json`    기기·앱 버전·설정·영상 형식, 끝날 때 통계
///
/// 모든 `t` 는 기기 부팅 후 초 (ARFrame.timestamp 와 같은 시계). 영상 시각 = t - meta.t0.
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Recorder()

    // UI (메인)
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var flags = 0
    @Published private(set) var lastError = ""
    @Published private(set) var currentName: String?

    static let videoWidth = 1280, videoHeight = 960

    private let queue = DispatchQueue(label: "recorder", qos: .utility)
    private let stateLock = NSLock()
    private var _active = false
    private var _pending = 0
    /// 다른 스레드에서 빨리 확인 (기록 중이 아니면 아무것도 하지 않음)
    var active: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _active }

    // recorder 큐 전용
    private var dir: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var transfer: VTPixelTransferSession?
    private var t0: Double?
    private var startDate = Date()
    private var files: [String: JSONLFile] = [:]
    private var frameCount = 0
    private var videoCount = 0
    private var dropped = 0
    private var lastVideoT: Double = -1
    private var lastTracking = ""
    private var resolutionLogged = CGSize.zero
    private var flagCount = 0

    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let location = CLLocationManager()
    private var timer: Timer?
    private var startUptime: Double = 0

    override init() {
        super.init()
        motionQueue.maxConcurrentOperationCount = 1
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.distanceFilter = kCLDistanceFilterNone
    }

    static var rootDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func freeSpace() -> Int64 {
        let v = try? rootDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: 시작·끝

    func start() {
        guard !isRecording else { return }
        if Recorder.freeSpace() < 1_500_000_000 {
            lastError = "저장 공간이 1.5GB 보다 적어 기록할 수 없습니다"
            return
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let d = Recorder.rootDir.appendingPathComponent(fmt.string(from: Date()), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        } catch {
            lastError = "폴더를 만들 수 없음: \(error.localizedDescription)"
            return
        }
        lastError = ""
        startDate = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        elapsed = 0; bytes = 0; flags = 0
        currentName = d.lastPathComponent
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true

        queue.sync {
            dir = d
            files = [:]
            for name in ["frames", "motion", "gps", "det", "marks", "events"] {
                files[name] = JSONLFile(url: d.appendingPathComponent("\(name).jsonl"))
            }
            t0 = nil; frameCount = 0; videoCount = 0; dropped = 0; lastVideoT = -1
            lastTracking = ""; resolutionLogged = .zero; flagCount = 0
            writer = nil; input = nil; adaptor = nil
            writeMeta(final: false)
        }
        stateLock.lock(); _active = true; stateLock.unlock()

        startMotion()
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        location.startUpdatingHeading()

        event("start")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        guard isRecording else { return }
        event("stop")
        stateLock.lock(); _active = false; stateLock.unlock()
        timer?.invalidate(); timer = nil
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        isRecording = false
        currentName = nil

        let bg = UIApplication.shared.beginBackgroundTask(withName: "기록 마무리")
        queue.async {
            let finish = {
                for f in self.files.values { f.close() }
                self.writeMeta(final: true)
                self.writer = nil; self.input = nil; self.adaptor = nil
                if let t = self.transfer { VTPixelTransferSessionInvalidate(t) }
                self.transfer = nil
                DispatchQueue.main.async {
                    RecordingStore.shared.reload()
                    UIApplication.shared.endBackgroundTask(bg)
                }
            }
            if let w = self.writer, w.status == .writing {
                self.input?.markAsFinished()
                w.finishWriting { self.queue.async(execute: finish) }
            } else {
                finish()
            }
        }
    }

    /// 화면이 이상할 때 사용자가 누르는 '문제 지점' 표시
    func flag() {
        guard active else { return }
        flags += 1
        event("flag", ["n": flags])
        queue.async { self.flagCount += 1 }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func tick() {
        elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        let d = queue.sync { dir }
        if let d {
            var total: Int64 = 0
            if let items = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey]) {
                for u in items { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            bytes = total
        }
        if Recorder.freeSpace() < 800_000_000 {
            lastError = "저장 공간이 부족해 기록을 멈췄습니다"
            stop()
        }
    }

    // MARK: 입력

    /// AR 큐에서 프레임마다 부름 (추적 상태와 상관없이 모든 프레임)
    func record(frame: ARFrame, pose: CarPose, speed: Float, offsetAngle: Float, offsetSamples: Int, ok: Bool) {
        guard active else { return }
        let cam = frame.camera
        let t = frame.timestamp
        let tf = cam.transform
        let K = cam.intrinsics
        let res = cam.imageResolution
        let trk = Recorder.trackingCode(cam.trackingState)
        let light = frame.lightEstimate?.ambientIntensity ?? -1
        let exposure = cam.exposureDuration
        let ev = cam.exposureOffset
        let pb = frame.capturedImage
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        // 기록 큐가 밀리면 카메라 버퍼를 붙잡지 않는다 (ARKit 프레임 부족 방지) — 영상만 건너뜀
        stateLock.lock()
        let keepImage = _pending < 3
        if keepImage { _pending += 1 }
        stateLock.unlock()
        let image: CVPixelBuffer? = keepImage ? pb : nil

        queue.async {
            defer { if image != nil { self.stateLock.lock(); self._pending -= 1; self.stateLock.unlock() } }
            guard self.active || self.writer != nil else { return }
            if self.t0 == nil { self.t0 = t }
            let rel = t - (self.t0 ?? t)
            if res != self.resolutionLogged {
                self.resolutionLogged = res
                self.eventLocked("resolution", ["w": Int(res.width), "h": Int(res.height)], t: t)
            }
            if trk != self.lastTracking {
                self.lastTracking = trk
                self.eventLocked("tracking", ["state": trk], t: t)
            }

            var vi = -1
            if let image {
                if self.writeVideo(image, rel: rel) { vi = self.videoCount - 1 } else { self.dropped += 1 }
            } else {
                self.dropped += 1
            }

            let c = tf.columns
            let rec: [String: Any] = [
                "i": self.frameCount, "t": t, "v": vi, "trk": trk, "ok": ok,
                // 열 우선 4×4 (ARKit camera.transform, 카메라 → 월드)
                "T": [c.0.x, c.0.y, c.0.z, c.0.w, c.1.x, c.1.y, c.1.z, c.1.w,
                      c.2.x, c.2.y, c.2.z, c.2.w, c.3.x, c.3.y, c.3.z, c.3.w].map { r($0) },
                "K": [K.columns.0.x, K.columns.1.y, K.columns.2.x, K.columns.2.y].map { r($0) },
                "exp": exposure, "ev": r(ev), "lux": r(Float(light)), "th": thermal,
                "o": [pose.origin.x, pose.origin.y, pose.origin.z].map { r($0) },
                "f": [pose.forward.x, pose.forward.z].map { r($0) },
                "spd": r(speed), "off": r(offsetAngle), "offn": offsetSamples,
            ]
            self.frameCount += 1
            self.files["frames"]?.write(rec)
        }
    }

    private func writeVideo(_ pb: CVPixelBuffer, rel: Double) -> Bool {
        if writer == nil { setupWriter() }
        guard let writer, let input, let adaptor else { return false }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                let msg = writer.error?.localizedDescription ?? "?"
                DispatchQueue.main.async { self.lastError = "영상 기록 오류: \(msg)" }
                return false
            }
            writer.startSession(atSourceTime: .zero)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData, rel > lastVideoT else { return false }
        guard let pool = adaptor.pixelBufferPool else { return false }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return false }
        if transfer == nil {
            var s: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
            transfer = s
        }
        guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: pb, to: out) == noErr else { return false }
        let pts = CMTime(seconds: rel, preferredTimescale: 600_000)
        guard adaptor.append(out, withPresentationTime: pts) else { return false }
        lastVideoT = rel
        videoCount += 1
        return true
    }

    private func setupWriter() {
        guard let dir else { return }
        let url = dir.appendingPathComponent("video.mov")
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            // 앱이 갑자기 꺼져도 앞부분은 살도록 조각 단위로 기록
            w.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            let codec: AVVideoCodecType = .hevc
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Recorder.videoWidth,
                AVVideoHeightKey: Recorder.videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ],
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: Recorder.videoWidth,
                kCVPixelBufferHeightKey as String: Recorder.videoHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            guard w.canAdd(inp) else { return }
            w.add(inp)
            writer = w; input = inp; adaptor = ad
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async { self.lastError = "영상 파일 오류: \(msg)" }
        }
    }

    /// 물체 인식 결과 (검출기 큐에서 부름)
    func recordDetections(t: Double, boxes: [[String: Any]], tracks: [TrackedObject]) {
        guard active else { return }
        let tr: [[String: Any]] = tracks.map {
            ["id": $0.id, "k": $0.kind.rawValue, "p": [r($0.pos.x), r($0.pos.y)],
             "vel": [r($0.vel.x), r($0.vel.y)], "w": r($0.width), "hits": $0.hits]
        }
        queue.async { self.files["det"]?.write(["t": t, "boxes": boxes, "tracks": tr]) }
    }

    /// 노면 표시 인식 결과 (0.5초마다)
    func recordMarks(sessionTime: Float, pose: CarPose, dets: [(MarkKind, SIMD2<Float>, SIMD2<Float>, Float)],
                     tracks: [RoadMark]) {
        guard active else { return }
        let t = ProcessInfo.processInfo.systemUptime
        let d: [[String: Any]] = dets.map {
            ["k": $0.0.name, "p": [r($0.1.x), r($0.1.y)], "h": [r($0.2.x), r($0.2.y)], "s": r($0.3)]
        }
        let tr: [[String: Any]] = tracks.map {
            ["id": $0.id, "k": $0.kind.name, "p": [r($0.pos.x), r($0.pos.y)], "h": [r($0.heading.x), r($0.heading.y)],
             "s": r($0.score), "hits": $0.hits]
        }
        let o = [r(pose.origin.x), r(pose.origin.z)]
        queue.async { self.files["marks"]?.write(["t": t, "st": r(sessionTime), "o": o, "dets": d, "tracks": tr]) }
    }

    func event(_ kind: String, _ extra: [String: Any] = [:]) {
        guard active else { return }
        let t = ProcessInfo.processInfo.systemUptime
        queue.async { self.eventLocked(kind, extra, t: t) }
    }

    private func eventLocked(_ kind: String, _ extra: [String: Any], t: Double) {
        var rec = extra
        rec["t"] = t
        rec["e"] = kind
        files["events"]?.write(rec)
    }

    // MARK: 센서

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.01
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] m, _ in
            guard let self, let m, self.active else { return }
            let q = m.attitude.quaternion
            let rr = m.rotationRate, ua = m.userAcceleration, g = m.gravity
            let rec: [String: Any] = [
                "t": m.timestamp,
                "q": [q.x, q.y, q.z, q.w].map { r6($0) },
                "rr": [rr.x, rr.y, rr.z].map { r6($0) },
                "ua": [ua.x, ua.y, ua.z].map { r6($0) },
                "g": [g.x, g.y, g.z].map { r6($0) },
            ]
            self.queue.async { self.files["motion"]?.write(rec) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active else { return }
        let nowUp = ProcessInfo.processInfo.systemUptime
        let nowDate = Date()
        for l in locations {
            let t = nowUp + l.timestamp.timeIntervalSince(nowDate)
            let rec: [String: Any] = [
                "t": t, "lat": l.coordinate.latitude, "lon": l.coordinate.longitude,
                "alt": r6(l.altitude), "hacc": r6(l.horizontalAccuracy), "vacc": r6(l.verticalAccuracy),
                "spd": r6(l.speed), "sacc": r6(l.speedAccuracy), "crs": r6(l.course), "cacc": r6(l.courseAccuracy),
                "date": l.timestamp.timeIntervalSince1970,
            ]
            queue.async { self.files["gps"]?.write(rec) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard active else { return }
        let nowUp = ProcessInfo.processInfo.systemUptime
        let t = nowUp + h.timestamp.timeIntervalSinceNow
        let rec: [String: Any] = ["t": t, "e": "heading", "mag": r6(h.magneticHeading), "true": r6(h.trueHeading),
                                  "acc": r6(h.headingAccuracy)]
        queue.async { self.files["gps"]?.write(rec) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        event("gps_error", ["msg": error.localizedDescription])
    }

    // MARK: 메타

    private func writeMeta(final: Bool) {
        guard let dir else { return }
        let d = UserDefaults.standard
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = Bundle.main.infoDictionary ?? [:]
        var meta: [String: Any] = [
            "format": 1,
            "start": ISO8601DateFormatter().string(from: startDate),
            "device": model,
            "ios": UIDevice.current.systemVersion,
            "app": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "video": ["file": "video.mov", "w": Recorder.videoWidth, "h": Recorder.videoHeight,
                      "note": "ARKit capturedImage (가로, 센서 방향) 를 축소. 세로 화면은 시계 방향 90° 회전"],
            "prefs": [
                "mountHeight": d.double(forKey: Prefs.mountHeight), "hoodCut": d.double(forKey: Prefs.hoodCut),
                "carFront": d.double(forKey: Prefs.carFront), "carRear": d.double(forKey: Prefs.carRear),
                "carWidth": d.double(forKey: Prefs.carWidth), "memorySec": d.double(forKey: Prefs.memorySec),
                "maxDistance": d.double(forKey: Prefs.maxDistance), "detection": d.bool(forKey: Prefs.detection),
                "roadMarks": d.bool(forKey: Prefs.roadMarks), "renderMode": d.integer(forKey: Prefs.renderMode),
            ],
            "clock": "t = 부팅 후 초 (ARFrame.timestamp, CMDeviceMotion.timestamp 와 같음)",
        ]
        if let t0 { meta["t0"] = t0 }
        if final {
            meta["end"] = ISO8601DateFormatter().string(from: Date())
            meta["frames"] = frameCount
            meta["videoFrames"] = videoCount
            meta["dropped"] = dropped
            meta["flags"] = flagCount
            meta["complete"] = true
        }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    static func trackingCode(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "normal"
        case .notAvailable: return "na"
        case .limited(let r):
            switch r {
            case .initializing: return "init"
            case .excessiveMotion: return "motion"
            case .insufficientFeatures: return "features"
            case .relocalizing: return "reloc"
            @unknown default: return "limited"
            }
        }
    }
}

private func r(_ v: Float) -> Double { (Double(v) * 1e5).rounded() / 1e5 }
private func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

/// 줄 단위 JSON 파일. 모아서 1초마다 쓴다 (recorder 큐에서만 사용)
final class JSONLFile {
    private let handle: FileHandle?
    private var buf = Data()
    private var lastFlush = Date()

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        buf.append(d)
        buf.append(0x0A)
        if buf.count > 256_000 || Date().timeIntervalSince(lastFlush) > 1 { flush() }
    }

    func flush() {
        guard !buf.isEmpty else { return }
        try? handle?.write(contentsOf: buf)
        buf.removeAll(keepingCapacity: true)
        lastFlush = Date()
    }

    func close() {
        flush()
        try? handle?.close()
    }
}
