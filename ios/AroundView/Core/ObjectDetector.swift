import Foundation
import Vision
import CoreML
import Combine
import simd

/// 인식된 물체 종류와 대략적인 크기 (폭, 길이, 높이 m)
enum ObjectKind: String {
    case car, truck, bus, motorbike, bicycle, person

    var size: (w: Float, l: Float, h: Float) {
        switch self {
        case .car: return (1.85, 4.5, 1.5)
        case .truck: return (2.4, 7.5, 2.8)
        case .bus: return (2.5, 11, 3.2)
        case .motorbike: return (0.8, 2.0, 1.4)
        case .bicycle: return (0.6, 1.8, 1.6)
        case .person: return (0.6, 0.6, 1.7)
        }
    }
    var label: String {
        switch self {
        case .car: return "승용차"
        case .truck: return "트럭"
        case .bus: return "버스"
        case .motorbike: return "오토바이"
        case .bicycle: return "자전거"
        case .person: return "사람"
        }
    }
    var isVehicle: Bool { self == .car || self == .truck || self == .bus }
}

/// 월드 좌표에서 추적 중인 물체
struct TrackedObject: Identifiable {
    let id: Int
    var kind: ObjectKind
    var pos: SIMD2<Float>      // 월드 (x, z)
    var vel: SIMD2<Float>      // m/s
    var heading: SIMD2<Float>  // 월드 (x, z) 단위벡터
    var width: Float
    var lastSeen: Float        // 세션 시간
    var hits: Int

    /// 현재 시각 기준 예측 위치 (최대 3초)
    func predicted(at t: Float) -> SIMD2<Float> {
        let dt = min(max(t - lastSeen, 0), 3)
        return pos + vel * dt
    }
}

/// 노면 기록에서 빼낼 화면 영역 (세로 화면 정규좌표, 좌상단 원점)
struct MaskBox { var minX, minY, maxX, maxY: Float }

final class ObjectDetector: ObservableObject {
    static let shared = ObjectDetector()

    @Published private(set) var objects: [TrackedObject] = []
    @Published private(set) var liveBoxes: [(CGRect, ObjectKind)] = []
    @Published private(set) var status = ""

    private let queue = DispatchQueue(label: "detector", qos: .userInitiated)
    private var request: VNCoreMLRequest?
    private let busyLock = NSLock()
    private var _busy = false
    private var busy: Bool {
        get { busyLock.lock(); defer { busyLock.unlock() }; return _busy }
        set { busyLock.lock(); _busy = newValue; busyLock.unlock() }
    }
    private var lastRun: Float = -10
    private var tracks: [TrackedObject] = []
    private var nextID = 1
    private let maskLock = NSLock()
    private var _mask: [MaskBox] = []
    private var _maskTime: Float = -10
    private var _snapshot: [TrackedObject] = []

    /// 렌더 스레드(SceneKit)에서 읽는 추적 목록
    func snapshotObjects() -> [TrackedObject] {
        maskLock.lock(); defer { maskLock.unlock() }
        return _snapshot
    }

    init() {
        queue.async { self.load() }
    }

    private func load() {
        do {
            guard let url = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc") else {
                publishStatus("인식 모델 없음"); return
            }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: cfg))
            let req = VNCoreMLRequest(model: model)
            req.imageCropAndScaleOption = .scaleFill
            request = req
            publishStatus("")
        } catch {
            publishStatus("인식 모델 오류: \(error.localizedDescription)")
        }
    }

    private func publishStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

    /// 노면 기록에서 제외할 상자 (최근 0.6초 이내 검출만)
    func maskBoxes(now: Float) -> [MaskBox] {
        maskLock.lock(); defer { maskLock.unlock() }
        return now - _maskTime < 0.6 ? _mask : []
    }

    func clear() {
        queue.async {
            self.tracks.removeAll()
            self.maskLock.lock(); self._mask = []; self._snapshot = []; self.maskLock.unlock()
            DispatchQueue.main.async { self.objects = []; self.liveBoxes = [] }
        }
    }

    /// AR 프레임마다 호출됨. 열 때마다 돌리지 않고 간격을 둔다.
    func submit(_ pb: CVPixelBuffer, snap: CameraSnap, pose: CarPose) {
        guard UserDefaults.standard.bool(forKey: Prefs.detection) else {
            if !tracks.isEmpty { clear() }
            return
        }
        let interval: Float
        switch ProcessInfo.processInfo.thermalState {
        case .serious: interval = 0.5
        case .critical: interval = 1.0
        default: interval = 0.1
        }
        guard !busy, snap.time - lastRun >= interval, request != nil else { return }
        busy = true
        lastRun = snap.time
        queue.async { self.run(pb, snap: snap, pose: pose) }
    }

    private func run(_ pb: CVPixelBuffer, snap: CameraSnap, pose: CarPose) {
        defer { busy = false }
        guard let request else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
        do { try handler.perform([request]) } catch { return }
        let obs = (request.results as? [VNRecognizedObjectObservation]) ?? []

        var dets: [(kind: ObjectKind, pos: SIMD2<Float>, width: Float, box: CGRect)] = []
        var masks: [MaskBox] = []
        var boxes: [(CGRect, ObjectKind)] = []
        let logging = Recorder.shared.active
        var logBoxes: [[String: Any]] = []
        for o in obs {
            guard let top = o.labels.first else { continue }
            if logging, top.confidence > 0.2 {
                // 세로 화면 정규좌표 (좌상단 원점) 상자 + 접지점 노면 위치
                let bb = o.boundingBox
                let rr = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
                var b: [String: Any] = ["k": top.identifier, "c": Double(top.confidence),
                                        "b": [rr.minX, rr.minY, rr.width, rr.height].map { (Double($0) * 1e4).rounded() / 1e4 }]
                if let g = snap.groundHit(portrait: CGPoint(x: rr.midX, y: rr.maxY)) {
                    b["g"] = [Double(g.x), Double(g.z)].map { ($0 * 1e3).rounded() / 1e3 }
                }
                logBoxes.append(b)
            }
            guard top.confidence > 0.35,
                  let kind = ObjectKind(rawValue: top.identifier) else { continue }
            let bb = o.boundingBox // 좌하단 원점
            let r = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height) // 좌상단 원점
            boxes.append((r, kind))
            let pad: CGFloat = 0.15
            masks.append(MaskBox(minX: Float(r.minX - r.width * pad), minY: Float(r.minY - r.height * pad),
                                 maxX: Float(r.maxX + r.width * pad), maxY: Float(r.maxY + r.height * 0.05)))

            // 바닥 접지점 (상자 아래쪽 가운데·좌·우) → 노면 위치
            guard let mid = snap.groundHit(portrait: CGPoint(x: r.midX, y: r.maxY)) else { continue }
            var width = kind.size.w
            if let l = snap.groundHit(portrait: CGPoint(x: r.minX, y: r.maxY)),
               let rr = snap.groundHit(portrait: CGPoint(x: r.maxX, y: r.maxY)) {
                let measured = simd_distance(SIMD2(l.x, l.z), SIMD2(rr.x, rr.z))
                width = min(max(measured, kind.size.w * 0.7), kind.size.w * 1.4)
            }
            // 보이는 면은 물체의 가까운 쪽 → 중심은 시선 방향으로 반 길이 더 들어간 곳
            let cam = SIMD2<Float>(snap.position.x, snap.position.z)
            var p = SIMD2<Float>(mid.x, mid.z)
            let ray = p - cam
            if simd_length(ray) > 0.1 {
                p += simd_normalize(ray) * (kind.size.l * 0.5)
            }
            dets.append((kind, p, width, r))
        }

        maskLock.lock(); _mask = masks; _maskTime = snap.time; maskLock.unlock()
        associate(dets, now: snap.time, pose: pose)

        let snapshot = tracks.filter { $0.hits >= 2 }
        maskLock.lock(); _snapshot = snapshot; maskLock.unlock()
        if logging { Recorder.shared.recordDetections(t: snap.stamp, boxes: logBoxes, tracks: tracks) }
        DispatchQueue.main.async {
            self.objects = snapshot
            self.liveBoxes = boxes
        }
    }

    /// 단순 최근접 연결 + 속도 지수평활
    private func associate(_ dets: [(kind: ObjectKind, pos: SIMD2<Float>, width: Float, box: CGRect)], now: Float, pose: CarPose) {
        var used = Set<Int>()
        for d in dets {
            var best = -1
            var bestDist: Float = .greatestFiniteMagnitude
            for (i, t) in tracks.enumerated() where !used.contains(i) {
                let compatible = t.kind == d.kind || (t.kind.isVehicle && d.kind.isVehicle)
                guard compatible else { continue }
                let dist = simd_distance(t.predicted(at: now), d.pos)
                let gate: Float = d.kind == .person ? 2.0 : 4.0
                if dist < gate, dist < bestDist { best = i; bestDist = dist }
            }
            if best >= 0 {
                var t = tracks[best]
                let dt = max(now - t.lastSeen, 0.05)
                let pred = t.predicted(at: now)
                let newPos = pred + (d.pos - pred) * 0.5
                var v = (newPos - t.pos) / dt
                if simd_length(v) > 45 { v = t.vel }
                t.vel = t.vel * 0.75 + v * 0.25
                t.pos = newPos
                t.width = t.width * 0.8 + d.width * 0.2
                t.lastSeen = now
                t.hits += 1
                if t.kind != d.kind, d.kind == .bus || d.kind == .truck { t.kind = d.kind }
                if simd_length(t.vel) > 2.0 { t.heading = simd_normalize(t.vel) }
                tracks[best] = t
                used.insert(best)
            } else {
                let fwd = SIMD2<Float>(pose.forward.x, pose.forward.z)
                tracks.append(TrackedObject(id: nextID, kind: d.kind, pos: d.pos, vel: .zero, heading: fwd,
                                            width: d.width, lastSeen: now, hits: 1))
                used.insert(tracks.count - 1)
                nextID += 1
            }
        }
        // 오래 못 본 물체, 너무 뒤로 멀어진 물체 제거
        tracks.removeAll { t in
            let age = now - t.lastSeen
            let car = pose.toCar(SIMD3(t.predicted(at: now).x, pose.origin.y, t.predicted(at: now).y))
            if t.hits < 2 { return age > 0.4 }
            return age > 6 || car.y < -40 || abs(car.x) > 30
        }
    }
}
