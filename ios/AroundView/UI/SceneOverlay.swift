import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import simd

/// 자차·주변 물체·노면 표시를 3D 모델로 그리는 오버레이 (테슬라식).
/// Metal 노면 화면과 같은 가상 카메라 값을 써서 위치가 맞는다.
struct SceneOverlay: UIViewRepresentable {
    var kind: VirtualCamera.Kind
    var mode: Int
    var zoom: Float

    func makeCoordinator() -> OverlayController { OverlayController() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.backgroundColor = .clear
        v.isOpaque = false
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = false
        v.preferredFramesPerSecond = 30
        v.rendersContinuously = true
        v.isUserInteractionEnabled = false
        v.scene = context.coordinator.scene
        v.pointOfView = context.coordinator.cameraNode
        v.delegate = context.coordinator
        v.isPlaying = true
        context.coordinator.set(kind: kind, mode: mode, zoom: zoom)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.set(kind: kind, mode: mode, zoom: zoom)
    }
}

/// 모델 한 종류: 원본 노드(바닥 가운데 원점, 앞 = -Z)와 원본 크기
struct ModelProto {
    let node: SCNNode
    let size: SIMD3<Float>   // 폭, 높이, 길이 (m)
}

enum ModelLibrary {
    static let bodyLight: UIColor = UIColor(white: 0.93, alpha: 1)
    static let bodyGray: UIColor = UIColor(red: 0.60, green: 0.63, blue: 0.68, alpha: 1)
    static let trim: UIColor = UIColor(white: 0.10, alpha: 1)

    static func material(_ color: UIColor, shiny: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = UIColor(white: shiny ? 0.55 : 0.2, alpha: 1)
        m.shininess = shiny ? 0.5 : 0.15
        return m
    }

    /// Assets3D/av_<name>.obj 를 읽어 재질을 body/trim 두 개로 바꿈. 실패하면 nil
    static func load(_ name: String, body: UIColor) -> ModelProto? {
        guard let url = Bundle.main.url(forResource: "av_\(name)", withExtension: "obj", subdirectory: "Assets3D") else {
            return nil
        }
        let asset = MDLAsset(url: url)
        let scene = SCNScene(mdlAsset: asset)
        let holder = SCNNode()
        for c in scene.rootNode.childNodes { holder.addChildNode(c) }
        let flat = holder.flattenedClone()
        guard let geo = flat.geometry else { return nil }
        let bodyMat = material(body, shiny: true)
        let trimMat = material(trim, shiny: true)
        if geo.materials.count >= 2 {
            geo.materials = geo.materials.enumerated().map { i, m in
                let n = (m.name ?? "").lowercased()
                if n.contains("trim") { return trimMat }
                if n.contains("body") { return bodyMat }
                return i == 0 ? bodyMat : trimMat
            }
        } else {
            geo.materials = [bodyMat]
        }
        let (mn, mx) = flat.boundingBox
        let size = SIMD3<Float>(Float(mx.x - mn.x), Float(mx.y - mn.y), Float(mx.z - mn.z))
        guard size.x > 0.01, size.y > 0.01, size.z > 0.01 else { return nil }
        return ModelProto(node: flat, size: size)
    }

    /// 모델을 못 읽었을 때 쓰는 상자 (바닥 가운데 원점)
    static func box(body: UIColor) -> ModelProto {
        let b = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.08)
        b.materials = [material(body, shiny: true)]
        let n = SCNNode(geometry: b)
        n.position = SCNVector3(0, 0.5, 0)
        let holder = SCNNode(); holder.addChildNode(n)
        return ModelProto(node: holder, size: SIMD3(1, 1, 1))
    }

    /// 바닥 그림자 (가운데 진하고 가장자리로 옅어지는 사각형)
    static let shadowImage: UIImage = {
        let s = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor.black.withAlphaComponent(0.55).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0.35, 1]) {
                ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                                                 endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
            }
        }
    }()

    static func shadow(width: Float, length: Float) -> SCNNode {
        let p = SCNPlane(width: CGFloat(width), height: CGFloat(length))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = shadowImage
        m.writesToDepthBuffer = false
        p.materials = [m]
        let n = SCNNode(geometry: p)
        n.eulerAngles.x = -.pi / 2
        n.position.y = 0.015
        n.renderingOrder = -5
        return n
    }
}

/// SceneKit 장면 관리. renderer(_:updateAtTime:) 은 SceneKit 렌더 스레드에서 불린다
final class OverlayController: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let world = SCNNode()        // 차량 좌표(GL) 기준
    private let marksRoot = SCNNode()
    private let objectsRoot = SCNNode()
    private var egoNode = SCNNode()
    private var egoDims = SIMD3<Float>(0, 0, 0)

    private let settingsLock = NSLock()
    private var kind: VirtualCamera.Kind = .chase
    private var mode = 2
    private var zoom: Float = 1

    private var protos: [String: ModelProto] = [:]
    private var objectNodes: [Int: (SCNNode, ObjectKind)] = [:]
    private var markNodes: [Int: (SCNNode, String)] = [:]
    private var markMaterials: [String: SCNMaterial] = [:]

    override init() {
        super.init()
        let cam = SCNCamera()
        cam.fieldOfView = CGFloat(VirtualCamera.fovyDeg)
        cam.projectionDirection = .vertical
        cam.zNear = Double(VirtualCamera.near)
        cam.zFar = Double(VirtualCamera.far)
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(world)
        world.addChildNode(marksRoot)
        world.addChildNode(objectsRoot)

        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.intensity = 550; amb.light?.color = UIColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(amb)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-1.0, 0.5, 0)
        scene.rootNode.addChildNode(sun)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .directional
        fill.light?.intensity = 300
        fill.eulerAngles = SCNVector3(-0.6, .pi + 0.4, 0)
        scene.rootNode.addChildNode(fill)

        for (k, color) in [("ego", ModelLibrary.bodyLight), ("car", ModelLibrary.bodyGray), ("truck", ModelLibrary.bodyGray),
                           ("bus", ModelLibrary.bodyGray), ("motorbike", ModelLibrary.bodyGray),
                           ("bicycle", ModelLibrary.bodyGray), ("person", UIColor(white: 0.78, alpha: 1))] {
            protos[k] = ModelLibrary.load(k, body: color) ?? ModelLibrary.box(body: color)
        }
        rebuildEgo()
    }

    func set(kind: VirtualCamera.Kind, mode: Int, zoom: Float) {
        settingsLock.lock(); self.kind = kind; self.mode = mode; self.zoom = zoom; settingsLock.unlock()
    }

    private func settings() -> (VirtualCamera.Kind, Int, Float) {
        settingsLock.lock(); defer { settingsLock.unlock() }
        return (kind, mode, zoom)
    }

    // MARK: 자차

    private func rebuildEgo() {
        let front = Prefs.f(Prefs.carFront), rear = Prefs.f(Prefs.carRear), width = Prefs.f(Prefs.carWidth)
        let dims = SIMD3<Float>(width, 1.45, front + rear)
        guard dims != egoDims else { return }
        egoDims = dims
        egoNode.removeFromParentNode()
        let n = SCNNode()
        if let p = protos["ego"] {
            let m = p.node.clone()
            m.simdScale = dims / p.size
            n.addChildNode(m)
        }
        n.addChildNode(ModelLibrary.shadow(width: dims.x + 0.6, length: dims.z + 0.8))
        n.simdPosition = SIMD3(0, 0, -(front - rear) / 2)
        objectsRoot.addChildNode(n)
        egoNode = n
    }

    // MARK: 갱신

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let (kind, mode, zoom) = settings()
        let size = renderer.currentViewport.size
        let aspect = Float(size.width / max(size.height, 1))
        let cam = VirtualCamera(kind: kind, aspect: aspect, zoom: zoom)
        let view = M4.lookAt(eye: cam.eye, center: cam.center, up: cam.up)
        cameraNode.simdTransform = view.inverse
        if let c = cameraNode.camera {
            c.usesOrthographicProjection = kind == .top
            c.orthographicScale = Double(cam.orthoHalfHeight)
        }

        rebuildEgo()
        let (pose, now) = PoseHolder.shared.get()
        updateObjects(pose: pose, now: now)
        updateMarks(pose: pose, now: now, show: mode != 0)
    }

    private func protoName(_ k: ObjectKind) -> String {
        switch k {
        case .car: return "car"
        case .truck: return "truck"
        case .bus: return "bus"
        case .motorbike: return "motorbike"
        case .bicycle: return "bicycle"
        case .person: return "person"
        }
    }

    /// 종류별 그릴 크기: 차량은 폭·길이·높이를 맞추고, 사람·이륜차는 비율 유지
    private func dims(for o: TrackedObject, proto p: ModelProto) -> SIMD3<Float> {
        let s = o.kind.size
        if o.kind.isVehicle {
            return SIMD3(o.width, s.h, s.l)
        }
        let k = s.h / p.size.y
        return p.size * k
    }

    private func updateObjects(pose: CarPose, now: Float) {
        let objs = ObjectDetector.shared.snapshotObjects()
        var seen = Set<Int>()
        for o in objs {
            let name = protoName(o.kind)
            guard let p = protos[name] else { continue }
            seen.insert(o.id)
            var entry = objectNodes[o.id]
            if entry == nil || entry!.1 != o.kind {
                entry?.0.removeFromParentNode()
                let n = SCNNode()
                let m = p.node.clone(); m.name = "model"
                n.addChildNode(m)
                let d = dims(for: o, proto: p)
                m.simdScale = d / p.size
                n.addChildNode(ModelLibrary.shadow(width: d.x + 0.4, length: d.z + 0.5))
                objectsRoot.addChildNode(n)
                entry = (n, o.kind)
                objectNodes[o.id] = entry
            }
            guard let (n, _) = entry else { continue }
            if o.kind.isVehicle, let m = n.childNode(withName: "model", recursively: false) {
                m.simdScale = dims(for: o, proto: p) / p.size
            }
            let pp = o.predicted(at: now)
            let c = pose.toCar(SIMD3(pp.x, pose.origin.y, pp.y))
            let d = pose.toCarDir(SIMD3(o.heading.x, 0, o.heading.y))
            n.simdPosition = SIMD3(c.x, 0, -c.y)
            n.simdEulerAngles = SIMD3(0, atan2f(-d.x, d.y), 0)
            let unseen = now - o.lastSeen
            n.opacity = CGFloat(unseen < 0.5 ? 1 : max(0.25, 1 - (unseen - 0.5) / 5))
        }
        for (id, e) in objectNodes where !seen.contains(id) {
            e.0.removeFromParentNode()
            objectNodes[id] = nil
        }
    }

    private func markMaterial(_ name: String) -> SCNMaterial? {
        if let m = markMaterials[name] { return m }
        guard let img = MarkCatalog.shared.images[name] else { return nil }
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.multiply.contents = UIColor(white: 0.96, alpha: 1)
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        markMaterials[name] = m
        return m
    }

    private func updateMarks(pose: CarPose, now: Float, show: Bool) {
        marksRoot.isHidden = !show
        guard show else { return }
        let marks = RoadMarkDetector.shared.visibleMarks(now: now)
        let mem = max(Prefs.f(Prefs.memorySec), 10)
        var seen = Set<Int>()
        for mk in marks {
            seen.insert(mk.id)
            var entry = markNodes[mk.id]
            if entry == nil || entry!.1 != mk.kind.name {
                entry?.0.removeFromParentNode()
                guard let mat = markMaterial(mk.kind.name) else { continue }
                let plane = SCNPlane(width: CGFloat(mk.kind.width), height: CGFloat(mk.kind.length))
                plane.materials = [mat]
                let pn = SCNNode(geometry: plane)
                pn.eulerAngles.x = -.pi / 2       // 그림 위쪽 → 앞(-Z)
                pn.renderingOrder = -10
                let n = SCNNode(); n.addChildNode(pn)
                marksRoot.addChildNode(n)
                entry = (n, mk.kind.name)
                markNodes[mk.id] = entry
            }
            guard let (n, _) = entry else { continue }
            let c = pose.toCar(SIMD3(mk.pos.x, pose.origin.y, mk.pos.y))
            let d = pose.toCarDir(SIMD3(mk.heading.x, 0, mk.heading.y))
            n.simdPosition = SIMD3(c.x, 0.02, -c.y)
            n.simdEulerAngles = SIMD3(0, atan2f(-d.x, d.y), 0)
            let age = now - mk.lastSeen
            n.opacity = CGFloat(max(0.35, 0.95 - 0.6 * age / mem))
        }
        for (id, e) in markNodes where !seen.contains(id) {
            e.0.removeFromParentNode()
            markNodes[id] = nil
        }
    }
}
