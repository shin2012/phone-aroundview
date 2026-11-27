import CoreMotion
import CoreLocation

/// 가속도계·자이로(100Hz)와 GPS를 앱 전체에서 하나씩만 돌린다.
/// 자세 추정(PoseFilter)에 쓰고, 주행 기록 중이면 기록기에도 넘긴다.
final class SensorHub: NSObject, CLLocationManagerDelegate {
    static let shared = SensorHub()

    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let location = CLLocationManager()
    private var running = false

    /// 가속도 (차 앞 방향, m/s²) — AR 큐에서 PoseFilter 로 넘김
    var onForwardAccel: ((Double, Float) -> Void)?
    /// GPS 속도 (m/s, 정확도)
    var onGPS: ((Double, Double, Double) -> Void)?

    override init() {
        super.init()
        motionQueue.maxConcurrentOperationCount = 1
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        guard !running else { return }
        running = true
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.01
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] m, _ in
                guard let self, let m else { return }
                // 뒤 카메라가 차 앞을 보므로 차 앞 = 기기 -Z
                self.onForwardAccel?(m.timestamp, Float(-m.userAcceleration.z * 9.81))
                Recorder.shared.recordMotion(m)
            }
        }
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        location.startUpdatingHeading()
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let nowUp = ProcessInfo.processInfo.systemUptime
        let nowDate = Date()
        for l in locations {
            let t = nowUp + l.timestamp.timeIntervalSince(nowDate)
            onGPS?(t, l.speed, l.speedAccuracy)
        }
        Recorder.shared.recordLocations(locations)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        Recorder.shared.recordHeading(h)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Recorder.shared.event("gps_error", ["msg": error.localizedDescription])
    }
}
