import Foundation

/// 자차 자세 추정 (순수 계산 — ARKit·센서 값만 받아 씀, 리눅스에서도 시험 가능).
///
/// 원칙
/// - 폰 카메라는 앞 유리 쪽을 본다 → **차 앞 = 카메라 방향**. 학습하는 것은 폰이 비뚤게 붙은 각도(±45° 이내)뿐.
///   예전에는 이 각도에 제한이 없어 첫 학습이 틀리면 앞뒤가 180° 뒤집힌 채로 굳을 수 있었다.
/// - 전진·후진 = 이동 방향이 카메라 쪽인지 반대쪽인지. 아주 느릴 때는 가속도계(차 앞 방향 성분)를 적분해 판정.
/// - 노면 높이는 차가 출렁여도 그대로 → 카메라 높이를 천천히 따라가게 한다 (출렁임이 노면 위치를 흔들지 않게).
/// - 화면 방향은 폰 떨림(고주파)을 걸러서 쓴다.
/// - GPS 속도와 ARKit 속도가 크게 다르면 ARKit 추적이 틀어진 것으로 보고 노면 기록을 멈춘다.
final class PoseFilter {
    struct Output {
        var origin: SIMD3<Float>      // 월드, 노면 높이
        var forward: SIMD2<Float>     // 월드 (x, z) 단위벡터 — 걸러진 차 방향
        var groundY: Float            // 노면 높이 (월드 y)
        var speed: Float              // m/s, 후진이면 음수
        var offset: Float             // 거치 비뚤어짐 (rad)
        var offsetSamples: Int
        var writeGround: Bool         // 이 프레임을 노면 기억에 써도 되는지
        var reason: String            // 쓰지 않는 이유 (기록·화면 표시용, 정상이면 "")
        var gpsSpeed: Float           // 최근 GPS 속도 (없으면 -1)
    }

    // 설정
    var mountHeight: Float = 1.25
    static let maxMountYaw: Float = 45 * .pi / 180
    static let groundTau: Double = 1.5      // 노면 높이 시상수 (초)
    static let headingTau: Double = 0.25    // 화면 방향 시상수 (초) — 폰 떨림 제거
    static let bumpPitchRate: Float = 0.45  // 이보다 빠른 끄덕임(rad/s)이면 노면 기록 쉼 (흔들림·번짐)

    // 상태
    private var history: [(t: Double, p: SIMD3<Float>, yaw: Float)] = []
    private(set) var offset: Float = 0
    private(set) var offsetSamples = 0
    private var camY: Float?
    private var headingVec: SIMD2<Float>?
    private var lastT: Double?
    private var lastPitch: Float?
    private var pitchRate: Float = 0
    private var lastYaw: Float?
    // 가속도계: 차 앞 방향 속도 (정지에서 출발할 때만 의미 있음)
    private var accelVel: Float = 0
    private var lastAccelT: Double?
    private var stillSince: Double?
    private var lastSign: Float = 1
    // GPS
    private var gpsSpeed: Float = -1
    private var gpsSpeedAcc: Float = -1
    private var gpsT: Double = -1

    func reset(keepOffset: Bool) {
        history.removeAll(); camY = nil; headingVec = nil; lastT = nil; lastPitch = nil; lastYaw = nil
        pitchRate = 0; accelVel = 0; lastAccelT = nil; stillSince = nil; lastSign = 1
        if !keepOffset { offset = 0; offsetSamples = 0 }
    }

    /// 가속도계 (중력 뺀 값, m/s²) 중 차 앞 방향 성분. 폰 뒤 카메라가 앞을 보므로 기기 -Z 성분.
    func accel(t: Double, forward a: Float) {
        defer { lastAccelT = t }
        guard let lt = lastAccelT else { return }
        let dt = Float(min(max(t - lt, 0), 0.05))
        // 정지 중이면 0 으로 붙잡고, 움직일 때는 서서히 새어 나가게 (적분 오차 누적 방지)
        if stillSince != nil { accelVel = 0; return }
        accelVel = accelVel * (1 - 0.3 * dt) + a * dt
    }

    func gps(t: Double, speed: Double, speedAccuracy: Double) {
        guard speed >= 0 else { return }
        gpsSpeed = Float(speed); gpsSpeedAcc = Float(speedAccuracy); gpsT = t
    }

    /// ARKit 프레임마다. pos = 카메라 위치, look = 카메라 광축(월드), ok = 추적 정상
    func frame(t: Double, pos: SIMD3<Float>, look: SIMD3<Float>, ok: Bool) -> Output {
        let dt = lastT.map { Float(min(max(t - $0, 0.001), 0.2)) } ?? (1 / 30)
        lastT = t

        // 카메라 방위 (광축 수평 성분). 광축이 거의 수직이면 직전 값 유지
        let lookH = SIMD2<Float>(look.x, look.z)
        var camYaw = lastYaw ?? 0
        if pfLen(lookH) > 0.15 { camYaw = atan2f(lookH.y, lookH.x) }
        lastYaw = camYaw

        // 끄덕임 속도 (과속방지턱·요철) — 노면 기록을 잠깐 쉴지 판단
        let pitch = asinf(max(-1, min(1, look.y)))
        if let lp = lastPitch {
            let r = abs(pitch - lp) / dt
            pitchRate = pitchRate * 0.6 + r * 0.4
        }
        lastPitch = pitch

        history.append((t, pos, camYaw))
        history.removeAll { t - $0.t > 0.6 }

        // 속도 (0.5초 창)
        var vel = SIMD2<Float>(0, 0)
        if let first = history.first, t - first.t > 0.25 {
            let w = Float(t - first.t)
            vel = SIMD2((pos.x - first.p.x) / w, (pos.z - first.p.z) / w)
        }
        let speedAbs = pfLen(vel)

        // 정지 판정 → 가속도 적분 초기화
        if speedAbs < 0.25 { if stillSince == nil { stillSince = t } } else { stillSince = nil }

        // 전진·후진: 카메라(=차 앞) 방향과 이동 방향의 내적
        let camFwd = SIMD2<Float>(cosf(camYaw + offset), sinf(camYaw + offset))
        var sign = lastSign
        if speedAbs > 0.7 {
            sign = pfDot(vel, camFwd) >= 0 ? 1 : -1
        } else if speedAbs > 0.2, abs(accelVel) > 0.15 {
            sign = accelVel >= 0 ? 1 : -1      // 막 출발할 때: 가속도계가 먼저 안다
        }
        lastSign = sign

        // 거치 비뚤어짐 학습: 충분히 빠르고 거의 직진일 때만, ±45° 안에서만
        if ok, speedAbs > 3, let first = history.first {
            let yawRate = abs(angleDiff(camYaw, first.yaw)) / Float(max(t - first.t, 0.01))
            if yawRate < 0.06 {
                var move = atan2f(vel.y, vel.x)
                if sign < 0 { move += .pi }           // 후진이면 이동 반대가 차 앞
                let est = angleDiff(move, camYaw)
                if abs(est) <= Self.maxMountYaw {
                    let alpha: Float = offsetSamples < 30 ? 0.1 : 0.02
                    offset += angleDiff(est, offset) * alpha
                    offsetSamples += 1
                }
            }
        }

        // 화면 방향: 폰 떨림 걸러내기 (벡터 평균이라 ±180° 경계 문제 없음)
        let rawFwd = SIMD2<Float>(cosf(camYaw + offset), sinf(camYaw + offset))
        if let hv = headingVec {
            let a = Float(1 - exp(-Double(dt) / Self.headingTau))
            headingVec = pfNorm(hv + (rawFwd - hv) * a)
        } else {
            headingVec = rawFwd
        }

        // 노면 높이: 출렁임에 따라가지 않게 천천히
        if let cy = camY {
            let a = Float(1 - exp(-Double(dt) / Self.groundTau))
            camY = cy + (pos.y - cy) * a
        } else {
            camY = pos.y
        }
        let groundY = camY! - mountHeight

        // 노면 기록 가능 여부
        var reason = ""
        if !ok { reason = "추적 불안정" }
        else if pitchRate > Self.bumpPitchRate { reason = "흔들림" }
        else if gpsSpeed >= 0, t - gpsT < 2.5, gpsSpeedAcc >= 0, gpsSpeedAcc < 2.0 {
            let diff = abs(gpsSpeed - speedAbs)
            if diff > max(3.0, 0.4 * gpsSpeed) { reason = "GPS 속도와 불일치" }
        }

        return Output(origin: SIMD3(pos.x, groundY, pos.z), forward: headingVec!, groundY: groundY,
                      speed: speedAbs * sign, offset: offset, offsetSamples: offsetSamples,
                      writeGround: reason.isEmpty, reason: reason,
                      gpsSpeed: (gpsSpeed >= 0 && t - gpsT < 2.5) ? gpsSpeed : -1)
    }
}

// simd 없이 쓰는 작은 도우미 (리눅스 시험용)
@inline(__always) func pfLen(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
@inline(__always) func pfDot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.x + a.y * b.y }
@inline(__always) func pfNorm(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let l = pfLen(v); return l > 1e-6 ? v / l : SIMD2(1, 0)
}

func angleDiff(_ a: Float, _ b: Float) -> Float {
    var d = a - b
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return d
}
