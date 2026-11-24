import Foundation

/// 사용자 설정. 렌더 스레드에서도 읽으므로 UserDefaults 를 직접 읽는다.
enum Prefs {
    static let mountHeight = "mountHeight"     // 노면에서 폰까지 높이 (m)
    static let hoodCut = "hoodCut"             // 화면 아래 본넷 가림 비율 (0~0.7)
    static let carFront = "carFront"           // 폰 → 앞범퍼 (m)
    static let carRear = "carRear"             // 폰 → 뒷범퍼 (m)
    static let carWidth = "carWidth"           // 차 폭 (m)
    static let memorySec = "memorySec"         // 노면 기억 시간 (초)
    static let maxDistance = "maxDistance"     // 노면 기록 최대 거리 (m)
    static let detection = "detection"         // 물체 인식 켜기
    static let roadMarks = "roadMarks"         // 노면 표시(화살표·횡단보도 등) 인식 켜기
    static let renderMode = "renderMode"       // 0 실사, 1 가상, 2 혼합
    static let viewKind = "viewKind"           // top / chase
    static let zoom = "zoom"
    static let acceptedNotice = "acceptedNotice"

    static func register() {
        UserDefaults.standard.register(defaults: [
            mountHeight: 1.25, hoodCut: 0.30, carFront: 2.0, carRear: 2.8, carWidth: 1.85,
            memorySec: 120.0, maxDistance: 22.0, detection: true, roadMarks: true, renderMode: 2,
            viewKind: VirtualCamera.Kind.chase.rawValue, zoom: 1.0, acceptedNotice: false,
        ])
    }

    static func f(_ key: String) -> Float { Float(UserDefaults.standard.double(forKey: key)) }
}
