import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.mountHeight) private var mountHeight = 1.25
    @AppStorage(Prefs.hoodCut) private var hoodCut = 0.3
    @AppStorage(Prefs.carFront) private var carFront = 2.0
    @AppStorage(Prefs.carRear) private var carRear = 2.8
    @AppStorage(Prefs.carWidth) private var carWidth = 1.85
    @AppStorage(Prefs.memorySec) private var memorySec = 120.0
    @AppStorage(Prefs.maxDistance) private var maxDistance = 22.0
    @AppStorage(Prefs.detection) private var detection = true
    @AppStorage(Prefs.roadMarks) private var roadMarks = true

    private var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("노면에서 폰 높이", value: $mountHeight, range: 0.7...1.8, step: 0.05, unit: "m")
                    row("본넷 가림 (화면 아래)", value: $hoodCut, range: 0...0.7, step: 0.01, unit: "%", percent: true)
                } header: { Text("거치") } footer: {
                    Text("본넷 가림은 미리보기의 빨간 영역이 본넷·대시보드를 덮도록 맞추세요. 높이가 틀리면 거리 비율이 늘거나 줄어듭니다.")
                }
                Section("차량 크기 (폰 위치 기준)") {
                    row("앞범퍼까지", value: $carFront, range: 0.5...3.5, step: 0.1, unit: "m")
                    row("뒷범퍼까지", value: $carRear, range: 1.5...5, step: 0.1, unit: "m")
                    row("차 폭", value: $carWidth, range: 1.4...2.4, step: 0.05, unit: "m")
                }
                Section {
                    row("노면 기억 시간", value: $memorySec, range: 15...300, step: 5, unit: "초")
                    row("노면 기록 거리", value: $maxDistance, range: 8...35, step: 1, unit: "m")
                    Toggle("차량·사람 인식", isOn: $detection)
                    Toggle("노면 표시 인식", isOn: $roadMarks)
                } header: { Text("처리") } footer: {
                    Text("기록 거리를 줄이면 먼 곳의 흐린 노면이 덜 섞입니다. 인식을 끄면 발열이 줄어듭니다. 노면 표시(화살표·횡단보도·정지선 등)는 가상·혼합 화면에서만 그립니다.")
                }
                Section {
                    HStack {
                        Text("버전")
                        Spacer()
                        Text(verbatim: versionText).monospacedDigit().foregroundStyle(.secondary)
                    }
                } header: { Text("정보") } footer: {
                    Text("3D 모델: Quaternius, Kenney, Grab3D (모두 CC0). 노면 표시 그림: 위키미디어 공용의 대한민국 노면표시 (퍼블릭 도메인).")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                     unit: String, percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: percent ? String(format: "%.0f%%", value.wrappedValue * 100)
                     : String(format: step < 1 ? "%.2f %@" : "%.0f %@", value.wrappedValue, unit))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
