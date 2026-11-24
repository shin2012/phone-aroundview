import SwiftUI

@main
struct AroundViewApp: App {
    init() {
        Prefs.register()
        ARManager.shared.onFrame = { pb, snap, pose in
            ObjectDetector.shared.submit(pb, snap: snap, pose: pose)
        }
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @StateObject private var ar = ARManager.shared
    @StateObject private var detector = ObjectDetector.shared
    @Environment(\.scenePhase) private var phase

    @AppStorage(Prefs.renderMode) private var mode = 2
    @AppStorage(Prefs.viewKind) private var kindRaw = VirtualCamera.Kind.chase.rawValue
    @AppStorage(Prefs.zoom) private var zoom = 1.0
    @AppStorage(Prefs.hoodCut) private var hoodCut = 0.3
    @AppStorage(Prefs.acceptedNotice) private var accepted = false
    @State private var showSettings = false
    @State private var pinchBase: Double?

    private var kind: VirtualCamera.Kind { VirtualCamera.Kind(rawValue: kindRaw) ?? .chase }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                AroundMetalView(kind: kind, mode: mode, zoom: Float(zoom))
                ObjectOverlay(kind: kind, zoom: Float(zoom))
            }
            .ignoresSafeArea()
            .gesture(MagnificationGesture()
                .onChanged { v in
                    if pinchBase == nil { pinchBase = zoom }
                    zoom = min(max((pinchBase ?? 1) * Double(v), 0.5), 3)
                }
                .onEnded { _ in pinchBase = nil })

            VStack(spacing: 10) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: Binding(get: { !accepted }, set: { _ in })) {
            NoticeView { accepted = true }
        }
        .onAppear { ar.start() }
        .onChange(of: phase) { _, p in
            if p == .active { ar.start() } else if p == .background { ar.pause() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: String(format: "%.0f", abs(ar.speedKmh)))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(ar.speedKmh < -1 ? "km/h 후진" : "km/h").font(.footnote).foregroundStyle(.secondary)
                }
                chip(ar.trackingText, color: ar.trackingOK ? .green : .orange)
                if !ar.headingLearned {
                    chip("방향 보정 중 · 직진해 주세요", color: .yellow)
                }
                if !ar.thermalText.isEmpty { chip(ar.thermalText, color: .red) }
                if !detector.status.isEmpty { chip(detector.status, color: .red) }
            }
            Spacer()
            cameraInset
        }
    }

    private var cameraInset: some View {
        let w: CGFloat = 108, h: CGFloat = 144
        return ZStack(alignment: .topLeading) {
            CameraPreviewView()
            Canvas { ctx, size in
                // 본넷 가림 영역
                let y = size.height * (1 - hoodCut)
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: size.height - y)),
                         with: .color(.red.opacity(0.35)))
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(.red), lineWidth: 1.5)
                for (r, k) in detector.liveBoxes {
                    let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                      width: r.width * size.width, height: r.height * size.height)
                    ctx.stroke(Path(rect), with: .color(k == .person ? .orange : .cyan), lineWidth: 1.2)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3)))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Picker("표시", selection: $mode) {
                Text("실사").tag(0)
                Text("가상").tag(1)
                Text("혼합").tag(2)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Picker("시점", selection: $kindRaw) {
                    ForEach(VirtualCamera.Kind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Button {
                    ar.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 40, height: 32)
                }
                .buttonStyle(.bordered)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 40, height: 32)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func chip(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

struct NoticeView: View {
    var onAccept: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("시험용 어라운드 뷰").font(.title.bold())
            Text("이 화면은 앞 카메라가 **조금 전에 찍은 노면**과 **인식한 물체의 추정 위치**로 만든 그림입니다.")
            VStack(alignment: .leading, spacing: 8) {
                Label("차 옆·뒤로 새로 들어온 사람·차는 보이지 않습니다.", systemImage: "exclamationmark.triangle")
                Label("거리와 위치는 추정값이라 틀릴 수 있습니다.", systemImage: "ruler")
                Label("운전 중에는 조작하지 마세요. 반드시 거울과 직접 확인을 우선하세요.", systemImage: "hand.raised")
                Label("폰을 세로로 앞유리에 고정하고, 처음에 잠시 직진하면 방향이 맞춰집니다.", systemImage: "iphone")
            }
            .font(.callout)
            Spacer()
            Button(action: onAccept) {
                Text("이해했습니다").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }
}
