#if DEBUG
import Foundation

/// UI-test fixtures have their own library and no account/network service.
enum SessionHistoryReview {
    static var requested: Bool { SessionDesignReview.argument("--history-review") != nil }
    static func store() -> PlayerStore {
        let mode = SessionDesignReview.argument("--history-review") ?? "empty"
        let root = URL.cachesDirectory.appendingPathComponent("SessionHistoryUIReview", isDirectory: true)
        if mode != "keep" { try? FileManager.default.removeItem(at: root) }
        let delay = min(60, max(0, Double(SessionDesignReview.argument("--history-save-delay") ?? "0") ?? 0))
        let player = PlayerStore(service: nil, queue: .init(root: root), archiveVideo: { source, item, library in
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try await library.retainVideo(source, for: item)
        })
        if mode == "filled" {
            for (index, touches) in [128, 64, 42].enumerated() {
                let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!
                let item = HistorySession(id: id, ownerID: nil, touches: touches,
                    durationMS: [74000, 39000, 26000][index], source: index == 1 ? .gallery : .recording,
                    completedAt: Date().addingTimeInterval(-Double(index) * 86400), syncState: .deviceOnly)
                try? player.history.save(item)
                if index == 0, let path = SessionDesignReview.argument("--history-review-video") {
                    Task { await player.history.retainVideo(URL(fileURLWithPath: path), for: item) }
                }
            }
        }
        return player
    }
}
#endif
