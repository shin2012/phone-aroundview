import SwiftUI
import UIKit

/// 설정 → 주행 기록 목록
struct RecordingsView: View {
    @StateObject private var store = RecordingStore.shared
    @StateObject private var rec = Recorder.shared
    @State private var server = RecordingStore.shared.server
    @State private var token = RecordingStore.shared.token
    @State private var shareURL: URL?
    @State private var zipping: String?
    @State private var confirmDelete: RecordingItem?

    var body: some View {
        List {
            Section {
                if store.items.isEmpty {
                    Text("기록이 없습니다. 주행 화면 아래 빨간 버튼으로 기록을 시작하세요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.items) { item in
                    row(item)
                        .swipeActions {
                            Button(role: .destructive) { confirmDelete = item } label: { Label("삭제", systemImage: "trash") }
                        }
                }
            } header: { Text("기록") } footer: {
                Text("파일 앱 → 나의 iPhone → 폰어라운드 → Recordings 에서도 볼 수 있습니다. 끝난 기록만 올리거나 공유할 수 있습니다.")
            }

            if !store.message.isEmpty {
                Section { Text(store.message).font(.callout) }
            }

            Section {
                TextField("서버 주소 (https://…)", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { store.server = server }
                SecureField("토큰", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { store.token = token }
                Button("저장") {
                    store.server = server
                    store.token = token
                    store.message = store.configured ? "업로드 서버를 저장했습니다" : "서버 주소와 토큰을 모두 넣어 주세요"
                }
            } header: { Text("업로드 서버") } footer: {
                Text("업로드는 16MB씩 나눠 보내고, 끊기면 다시 눌렀을 때 이어서 올립니다. 와이파이에서 화면을 켠 채 올리세요.")
            }
        }
        .navigationTitle("주행 기록")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.reload()
            server = store.server
            token = store.token
        }
        .sheet(item: Binding(get: { shareURL.map { ShareTarget(url: $0) } }, set: { shareURL = $0?.url })) { t in
            ActivitySheet(items: [t.url])
        }
        .confirmationDialog("이 기록을 지울까요?", isPresented: Binding(get: { confirmDelete != nil },
                                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let item = confirmDelete { store.delete(item) }
                confirmDelete = nil
            }
            Button("취소", role: .cancel) { confirmDelete = nil }
        }
    }

    @ViewBuilder
    private func row(_ item: RecordingItem) -> some View {
        let isCurrent = rec.isRecording && rec.currentName == item.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: Self.title(item.date)).font(.headline)
                Spacer()
                if item.uploaded {
                    Label("올림", systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.green)
                }
            }
            HStack(spacing: 10) {
                if isCurrent {
                    Text("기록 중").foregroundStyle(.red)
                } else if !item.complete {
                    Text("끝나지 않음").foregroundStyle(.orange)
                } else {
                    Text(verbatim: Self.duration(item.duration))
                }
                Text(verbatim: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                if item.flags > 0 { Label("\(item.flags)", systemImage: "flag.fill").foregroundStyle(.yellow) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()

            if store.uploadingID == item.id {
                HStack {
                    ProgressView(value: store.progress)
                    Text(verbatim: String(format: "%.0f%%", store.progress * 100)).font(.caption).monospacedDigit()
                    Button("멈춤") { store.cancelUpload() }.buttonStyle(.bordered).controlSize(.small)
                }
            } else if item.complete && !isCurrent {
                HStack(spacing: 8) {
                    Button {
                        store.upload(item)
                    } label: {
                        Label(item.uploaded ? "다시 올리기" : "서버에 올리기", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(store.uploadingID != nil)
                    Button {
                        zipping = item.id
                        Task {
                            let url = await store.zip(item)
                            zipping = nil
                            if let url { shareURL = url } else { store.message = "압축에 실패했습니다" }
                        }
                    } label: {
                        if zipping == item.id { ProgressView() } else { Label("공유", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(zipping != nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    static func title(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E) HH:mm:ss"
        return f.string(from: d)
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return m > 0 ? "\(m)분 \(sec)초" : "\(sec)초"
    }
}

private struct ShareTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
