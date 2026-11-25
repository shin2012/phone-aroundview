import Foundation
import Combine
import Security
import UIKit

/// 저장된 기록 하나
struct RecordingItem: Identifiable, Hashable {
    let id: String        // 폴더 이름 (yyyyMMdd_HHmmss)
    let url: URL
    var date: Date
    var duration: Double  // 초 (끝난 기록만)
    var bytes: Int64
    var flags: Int
    var complete: Bool
    var uploaded: Bool
}

/// 기록 목록 + 서버 업로드
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var items: [RecordingItem] = []
    @Published private(set) var uploadingID: String?
    @Published private(set) var progress: Double = 0
    @Published var message = ""

    private var uploadTask: Task<Void, Never>?
    /// 업로드 상태 표시 파일 (서버로 보내지 않음)
    static let markerName = ".uploaded"
    static let chunk = 16 * 1024 * 1024

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Recorder.rootDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        var out: [RecordingItem] = []
        for d in dirs where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let name = d.lastPathComponent
            var bytes: Int64 = 0
            for f in Self.uploadFiles(in: d) {
                bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            var duration = 0.0, flags = 0, complete = false
            if let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                complete = meta["complete"] as? Bool ?? false
                flags = meta["flags"] as? Int ?? 0
                let iso = ISO8601DateFormatter()
                if let s = meta["start"] as? String, let e = meta["end"] as? String,
                   let a = iso.date(from: s), let b = iso.date(from: e) { duration = b.timeIntervalSince(a) }
            }
            let uploaded = fm.fileExists(atPath: d.appendingPathComponent(Self.markerName).path)
            out.append(RecordingItem(id: name, url: d, date: fmt.date(from: name) ?? Date.distantPast,
                                     duration: duration, bytes: bytes, flags: flags, complete: complete,
                                     uploaded: uploaded))
        }
        items = out.sorted { $0.id > $1.id }
    }

    static func uploadFiles(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return all.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func delete(_ item: RecordingItem) {
        if Recorder.shared.isRecording, Recorder.shared.currentName == item.id { return }
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    /// 공유 시트용 zip (임시 폴더)
    func zip(_ item: RecordingItem) async -> URL? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: URL?
                var err: NSError?
                NSFileCoordinator().coordinate(readingItemAt: item.url, options: [.forUploading], error: &err) { zipURL in
                    let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.id).zip")
                    try? FileManager.default.removeItem(at: dst)
                    if (try? FileManager.default.copyItem(at: zipURL, to: dst)) != nil { result = dst }
                }
                cont.resume(returning: result)
            }
        }
    }

    // MARK: 업로드

    var server: String {
        get { UserDefaults.standard.string(forKey: "uploadServer") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "uploadServer") }
    }
    var token: String {
        get { Keychain.get("uploadToken") ?? "" }
        set { Keychain.set("uploadToken", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    var configured: Bool { !server.isEmpty && !token.isEmpty }

    /// aroundview://setup?server=https://...&token=...
    func handle(url: URL) -> Bool {
        guard url.scheme == "aroundview", url.host == "setup",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        if let s = q.first(where: { $0.name == "server" })?.value { server = s }
        if let t = q.first(where: { $0.name == "token" })?.value { token = t }
        objectWillChange.send()
        message = configured ? "업로드 서버를 설정했습니다" : "서버 주소나 토큰이 비어 있습니다"
        return true
    }

    func cancelUpload() {
        uploadTask?.cancel()
    }

    func upload(_ item: RecordingItem) {
        guard uploadingID == nil else { return }
        guard configured else { message = "설정에서 업로드 서버를 먼저 정해 주세요"; return }
        guard item.complete else { message = "끝나지 않은 기록은 올릴 수 없습니다"; return }
        uploadingID = item.id
        progress = 0
        message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "기록 업로드")
        uploadTask = Task {
            let result: String
            do {
                try await self.send(item)
                try? Data().write(to: item.url.appendingPathComponent(Self.markerName))
                result = "올렸습니다: \(item.id)"
            } catch is CancellationError {
                result = "업로드를 멈췄습니다 (다시 누르면 이어서 올립니다)"
            } catch let e as URLError where e.code == .cancelled {
                result = "업로드를 멈췄습니다 (다시 누르면 이어서 올립니다)"
            } catch {
                result = "업로드 실패: \(error.localizedDescription)"
            }
            await MainActor.run {
                self.uploadingID = nil
                self.message = result
                if !Recorder.shared.isRecording { UIApplication.shared.isIdleTimerDisabled = false }
                self.reload()
                UIApplication.shared.endBackgroundTask(bg)
            }
        }
    }

    private struct UploadError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard let url = URL(string: base + path) else { throw UploadError(text: "서버 주소가 올바르지 않습니다") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func check(_ resp: URLResponse, _ data: Data, allow: Set<Int> = [200]) throws -> [String: Any] {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard allow.contains(code) else {
            if code == 401 { throw UploadError(text: "토큰이 맞지 않습니다 (401)") }
            throw UploadError(text: (obj["error"] as? String) ?? "서버 응답 \(code)")
        }
        return obj
    }

    private func send(_ item: RecordingItem) async throws {
        let name = item.id
        let files = Self.uploadFiles(in: item.url)
        var sizes: [String: Int64] = [:]
        for f in files { sizes[f.lastPathComponent] = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let total = max(sizes.values.reduce(0, +), 1)

        // 서버에 이미 있는 크기 (이어 올리기)
        let (d0, r0) = try await URLSession.shared.data(for: try request("/api/sessions/\(name)"))
        let have = (try check(r0, d0)["files"] as? [String: Any]) ?? [:]
        var sent: Int64 = 0

        for f in files {
            let fname = f.lastPathComponent
            let size = sizes[fname] ?? 0
            var offset = Int64((have[fname] as? NSNumber)?.int64Value ?? 0)
            if offset > size { offset = 0 } // 서버 쪽이 더 크면 처음부터
            sent += offset
            let fh = try FileHandle(forReadingFrom: f)
            defer { try? fh.close() }
            repeat {
                try Task.checkCancellation()
                try fh.seek(toOffset: UInt64(offset))
                let chunk = try fh.read(upToCount: Self.chunk) ?? Data()
                var req = try request("/api/sessions/\(name)/files/\(fname)?offset=\(offset)&total=\(size)", method: "PUT")
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (d, r) = try await URLSession.shared.upload(for: req, from: chunk)
                let obj = try check(r, d, allow: [200, 409])
                let newSize = Int64((obj["size"] as? NSNumber)?.int64Value ?? -1)
                guard newSize >= 0 else { throw UploadError(text: "서버 응답 형식 오류") }
                sent += newSize - offset
                offset = newSize
                let p = Double(sent) / Double(total)
                await MainActor.run { self.progress = min(p, 1) }
            } while offset < size
        }

        var done = try request("/api/sessions/\(name)/done", method: "POST")
        done.setValue("application/json", forHTTPHeaderField: "Content-Type")
        done.httpBody = try JSONSerialization.data(withJSONObject: ["files": sizes])
        let (d, r) = try await URLSession.shared.data(for: done)
        _ = try check(r, d)
    }
}

/// 업로드 토큰 저장 (키체인)
enum Keychain {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
