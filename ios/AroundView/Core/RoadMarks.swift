import Foundation
import Metal
import UIKit
import simd

/// 노면 표시 종류 (RoadMarks/marks.json 의 이름과 같음). 이름이 '_' 로 시작하면 방해용(차선) — 그리지 않음
struct MarkKind: Hashable {
    let name: String
    let width: Float   // m (오른쪽 방향)
    let length: Float  // m (진행 방향)
    var isDistractor: Bool { name.hasPrefix("_") }

    var label: String {
        switch name {
        case "straight": return "직진"
        case "left": return "좌회전"
        case "right": return "우회전"
        case "straight_left": return "직진·좌회전"
        case "straight_right": return "직진·우회전"
        case "uturn": return "유턴"
        case "crosswalk_ahead": return "횡단보도 예고"
        case "stop_line": return "정지선"
        case "crosswalk": return "횡단보도"
        case "bicycle": return "자전거"
        case "yield": return "양보"
        default: return name
        }
    }
}

/// 월드에 고정된 인식 결과
struct RoadMark: Identifiable {
    let id: Int
    var kind: MarkKind
    var pos: SIMD2<Float>       // 월드 (x, z)
    var heading: SIMD2<Float>   // 월드 (x, z) 단위벡터 (표시의 '앞')
    var score: Float            // 누적 점수
    var hits: Int
    var lastSeen: Float
    var visible: Bool { hits >= 2 || score >= 0.85 }
}

/// 템플릿 모음: 그림(흰색+투명) → 패치 해상도로 회전·축소한 격자 (평균 0, 길이 1)
final class MarkCatalog {
    static let shared = MarkCatalog()

    let kinds: [MarkKind]
    private(set) var images: [String: UIImage] = [:]

    private init() {
        var list: [MarkKind] = []
        if let url = Bundle.main.url(forResource: "marks", withExtension: "json", subdirectory: "RoadMarks"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (name, v) in obj.sorted(by: { $0.key < $1.key }) {
                let w = (v["w"] as? NSNumber)?.floatValue ?? 1
                let l = (v["l"] as? NSNumber)?.floatValue ?? 1
                list.append(MarkKind(name: name, width: w, length: l))
                if let p = Bundle.main.url(forResource: "mark_\(name)", withExtension: "png", subdirectory: "RoadMarks"),
                   let img = UIImage(contentsOfFile: p.path) {
                    images[name] = img
                }
            }
        }
        // 방해 템플릿: 차선 점선·실선이 직진 화살표로 오인되지 않게
        list.append(MarkKind(name: "_dash", width: 0.15, length: 3.0))
        list.append(MarkKind(name: "_line", width: 0.15, length: 6.0))
        kinds = list
    }

    /// 그림의 알파값 (행 0 = 그림 위쪽 = 앞쪽)
    func alpha(_ name: String) -> (data: [Float], w: Int, h: Int)? {
        if name.hasPrefix("_") { return ([Float](repeating: 1, count: 8 * 64), 8, 64) }
        guard let cg = images[name]?.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { a[i] = Float(bytes[i * 4 + 3]) / 255 }
        return (a, w, h)
    }

    /// tools/mark_match_sim.py 의 raster() 와 같은 계산. 행 = 앞(+Z) 증가, 열 = 오른쪽(+X) 증가
    static func rasterize(alpha: [Float], aw: Int, ah: Int, width wm: Float, length lm: Float,
                          ppm: Float, angleDeg: Float, margin: Float = 0.4, ss: Int = 4) -> (v: [Float], w: Int, h: Int) {
        let th = angleDeg * .pi / 180
        let c = cosf(th), s = sinf(th)
        let hw = wm / 2, hl = lm / 2
        let ex = abs(hw * c) + abs(hl * s) + margin
        let ez = abs(hw * s) + abs(hl * c) + margin
        let W = Int(ceilf(2 * ex * ppm)) | 1
        let H = Int(ceilf(2 * ez * ppm)) | 1
        var out = [Float](repeating: 0, count: W * H)
        let inv = 1 / Float(ss * ss)
        for j in 0..<H {
            for i in 0..<W {
                var acc: Float = 0
                for sj in 0..<ss {
                    for si in 0..<ss {
                        let X = (Float(i) + (Float(si) + 0.5) / Float(ss)) / ppm - Float(W) / (2 * ppm)
                        let Z = (Float(j) + (Float(sj) + 0.5) / Float(ss)) / ppm - Float(H) / (2 * ppm)
                        let u = X * c + Z * s
                        let v = -X * s + Z * c
                        let px = (u + hw) / wm * Float(aw)
                        let py = (hl - v) / lm * Float(ah)
                        if px >= 0, px < Float(aw), py >= 0, py < Float(ah) {
                            acc += alpha[Int(py) * aw + Int(px)]
                        }
                    }
                }
                out[j * W + i] = acc * inv
            }
        }
        return (out, W, H)
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let mean = v.reduce(0, +) / Float(max(v.count, 1))
        var t = v.map { $0 - mean }
        let n = sqrtf(t.reduce(0) { $0 + $1 * $1 })
        if n > 0 { t = t.map { $0 / n } }
        return t
    }
}

/// 노면 기억에서 차 앞뒤 패치를 뽑아 GPU 로 템플릿 매칭 → 월드 고정 노면 표시 목록
final class RoadMarkDetector {
    static let shared = RoadMarkDetector()

    // tools/mark_match_sim.py 와 같은 값
    let ppm: Float = 5
    let x0: Float = -6, x1: Float = 6, z0: Float = -12, z1: Float = 24
    let angles: [Float] = [-6, 0, 6]
    let threshold: Float = 0.62
    let radius: Float = 1.6

    private let device: MTLDevice
    private let patchPS: MTLComputePipelineState?
    private let matchPS: MTLComputePipelineState?
    private let patchTex: MTLTexture?
    private var tplBuf: MTLBuffer?
    private var infoBuf: MTLBuffer?
    private var scoreBuf: MTLBuffer?
    private var tplKinds: [(MarkKind, Float)] = []
    private let W: Int, H: Int
    private var busy = false
    private var lastRun: Float = -10
    private let lock = NSLock()
    private var tracks: [RoadMark] = []
    private var nextID = 1
    private let work = DispatchQueue(label: "roadmarks", qos: .utility)

    private init() {
        let mem = GroundMemory.shared
        device = mem.device
        W = Int((x1 - x0) * ppm); H = Int((z1 - z0) * ppm)
        patchPS = (mem.library.makeFunction(name: "paintPatch")).flatMap { try? mem.device.makeComputePipelineState(function: $0) }
        matchPS = (mem.library.makeFunction(name: "matchMarks")).flatMap { try? mem.device.makeComputePipelineState(function: $0) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        td.storageMode = .private
        patchTex = device.makeTexture(descriptor: td)
        work.async { self.buildTemplates() }
    }

    private func buildTemplates() {
        let cat = MarkCatalog.shared
        var flat: [Float] = []
        var info: [SIMD4<Int32>] = []
        var kinds: [(MarkKind, Float)] = []
        for k in cat.kinds {
            guard let a = cat.alpha(k.name) else { continue }
            for ang in angles {
                let r = MarkCatalog.rasterize(alpha: a.data, aw: a.w, ah: a.h, width: k.width, length: k.length,
                                              ppm: ppm, angleDeg: ang)
                info.append(SIMD4(Int32(flat.count), Int32(r.w), Int32(r.h), 0))
                flat += MarkCatalog.normalize(r.v)
                kinds.append((k, ang))
            }
        }
        guard !flat.isEmpty else { return }
        let tb = device.makeBuffer(bytes: flat, length: flat.count * 4, options: .storageModeShared)
        let ib = device.makeBuffer(bytes: info, length: info.count * MemoryLayout<SIMD4<Int32>>.stride, options: .storageModeShared)
        let sb = device.makeBuffer(length: W * H * kinds.count * 4, options: .storageModeShared)
        lock.lock()
        tplBuf = tb; infoBuf = ib; scoreBuf = sb; tplKinds = kinds
        lock.unlock()
    }

    func clear() {
        lock.lock(); tracks.removeAll(); lock.unlock()
    }

    /// 화면에 그릴 것 (기억 시간 지난 것은 제외)
    func visibleMarks(now: Float) -> [RoadMark] {
        let mem = max(Prefs.f(Prefs.memorySec), 10)
        lock.lock(); defer { lock.unlock() }
        return tracks.filter { $0.visible && now - $0.lastSeen < mem }
    }

    /// 렌더러가 프레임마다 부름. 0.5초마다 같은 명령 버퍼에 패치·매칭을 넣는다
    func maybeEncode(cb: MTLCommandBuffer, pose: CarPose, time: Float, color: MTLTexture, meta: MTLTexture,
                     grid: SIMD4<Float>) {
        guard UserDefaults.standard.bool(forKey: Prefs.roadMarks),
              time - lastRun >= 0.5, let patchPS, let matchPS, let patchTex else { return }
        lock.lock()
        let ready = !busy && tplBuf != nil
        let tb = tplBuf, ib = infoBuf, sb = scoreBuf, kinds = tplKinds
        if ready { busy = true }
        lock.unlock()
        guard ready, let tb, let ib, let sb, let enc = cb.makeComputeCommandEncoder() else { return }
        lastRun = time

        struct PatchU { var car: SIMD4<Float>; var grid: SIMD4<Float>; var patch: SIMD4<Float> }
        var u = PatchU(car: SIMD4(pose.origin.x, pose.origin.z, pose.forward.x, pose.forward.z),
                       grid: grid, patch: SIMD4(x0, z0, ppm, 0))
        enc.setComputePipelineState(patchPS)
        enc.setTexture(color, index: 0)
        enc.setTexture(meta, index: 1)
        enc.setTexture(patchTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<PatchU>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (W + 15) / 16, height: (H + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))

        var dims = SIMD4<UInt32>(UInt32(W), UInt32(H), UInt32(kinds.count), 0)
        enc.setComputePipelineState(matchPS)
        enc.setTexture(patchTex, index: 0)
        enc.setBuffer(tb, offset: 0, index: 0)
        enc.setBuffer(ib, offset: 0, index: 1)
        enc.setBuffer(sb, offset: 0, index: 2)
        enc.setBytes(&dims, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: (W + 7) / 8, height: (H + 7) / 8, depth: kinds.count),
                                 threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()

        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.work.async {
                self.process(scores: sb, kinds: kinds, pose: pose, time: time)
                self.lock.lock(); self.busy = false; self.lock.unlock()
            }
        }
    }

    private struct Cand { var score: Float; var t: Int; var X: Float; var Z: Float }

    private func process(scores: MTLBuffer, kinds: [(MarkKind, Float)], pose: CarPose, time: Float) {
        let p = scores.contents().bindMemory(to: Float.self, capacity: W * H * kinds.count)
        var cands: [Cand] = []
        for t in 0..<kinds.count {
            let base = t * W * H
            for y in 1..<(H - 1) {
                for x in 1..<(W - 1) {
                    let v = p[base + y * W + x]
                    guard v >= threshold else { continue }
                    var isMax = true
                    for dy in -1...1 where isMax {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            if p[base + (y + dy) * W + x + dx] > v { isMax = false; break }
                        }
                    }
                    if isMax {
                        cands.append(Cand(score: v, t: t, X: x0 + (Float(x) + 0.5) / ppm, Z: z0 + (Float(y) + 0.5) / ppm))
                    }
                }
            }
        }
        cands.sort { $0.score > $1.score }
        var keep: [Cand] = []
        for c in cands {
            let ck = kinds[c.t].0
            let ok = keep.allSatisfy { k in
                let both = ck.name == "crosswalk" && kinds[k.t].0.name == "crosswalk"
                return simd_distance(SIMD2(c.X, c.Z), SIMD2(k.X, k.Z)) > (both ? 0.9 : radius)
            }
            if ok { keep.append(c) }
        }

        // 차 좌표 → 월드
        let f = SIMD2<Float>(pose.forward.x, pose.forward.z)
        let r = SIMD2<Float>(-f.y, f.x)
        let o = SIMD2<Float>(pose.origin.x, pose.origin.z)
        var dets: [(MarkKind, SIMD2<Float>, SIMD2<Float>, Float)] = []
        for c in keep {
            let (kind, ang) = kinds[c.t]
            if kind.isDistractor { continue }
            let th = ang * .pi / 180
            let hCar = SIMD2<Float>(-sinf(th), cosf(th))      // (X, Z)
            let world = o + r * c.X + f * c.Z
            let hw = simd_normalize(r * hCar.x + f * hCar.y)
            dets.append((kind, world, hw, c.score))
        }
        merge(dets, now: time, pose: pose)
        if Recorder.shared.active {
            lock.lock(); let snapshot = tracks; lock.unlock()
            Recorder.shared.recordMarks(sessionTime: time, pose: pose, dets: dets, tracks: snapshot)
        }
    }

    private func merge(_ dets: [(MarkKind, SIMD2<Float>, SIMD2<Float>, Float)], now: Float, pose: CarPose) {
        lock.lock(); defer { lock.unlock() }
        for (kind, pos, hd, s) in dets {
            let gate: Float = kind.name == "crosswalk" ? 0.5 : 1.2
            if let i = tracks.firstIndex(where: { $0.kind.name == kind.name && simd_distance($0.pos, pos) < gate }) {
                var t = tracks[i]
                let w = s / (t.score + s)
                t.pos += (pos - t.pos) * w
                t.heading = simd_normalize(t.heading + (hd - t.heading) * w)
                t.score = min(t.score + s, 10)
                t.hits += 1
                t.lastSeen = now
                tracks[i] = t
            } else if let i = tracks.firstIndex(where: { $0.kind.name != kind.name && simd_distance($0.pos, pos) < radius }) {
                // 같은 자리 다른 종류: 점수가 높은 쪽으로 바꿈
                if s > tracks[i].score / Float(max(tracks[i].hits, 1)) + 0.05 {
                    tracks[i].kind = kind; tracks[i].pos = pos; tracks[i].heading = hd
                    tracks[i].score = s; tracks[i].hits = 1; tracks[i].lastSeen = now
                }
            } else {
                tracks.append(RoadMark(id: nextID, kind: kind, pos: pos, heading: hd, score: s, hits: 1, lastSeen: now))
                nextID += 1
            }
        }
        let mem = max(Prefs.f(Prefs.memorySec), 10)
        let o = SIMD2<Float>(pose.origin.x, pose.origin.z)
        tracks.removeAll { t in
            (t.hits < 2 && now - t.lastSeen > 3) || now - t.lastSeen > mem || simd_distance(t.pos, o) > 120
        }
    }
}
