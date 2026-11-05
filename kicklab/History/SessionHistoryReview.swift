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
        if mode == "filled" || mode == "editable" || mode == "legacy-timed" {
            for (index, touches) in [128, 64, 42].enumerated() {
                let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!
                let editable = mode == "editable" && index == 0
                let timed = mode == "legacy-timed" && index == 0
                var item = HistorySession(id: id, ownerID: nil, touches: editable || timed ? 2 : touches,
                    durationMS: editable || timed ? 1500 : [74000, 39000, 26000][index], source: index == 1 ? .gallery : .recording,
                    completedAt: Date().addingTimeInterval(-Double(index) * 86400), syncState: .deviceOnly)
                if timed { item.touchTimesMS = [300, 1000] }
                try? player.history.save(item)
                if index == 0, let path = SessionDesignReview.argument("--history-review-video") {
                    if editable {
                        let summary = SessionSummary.make(touches: 2, duration: 1.5, bestCombo: 2, personalBest: 2,
                            videoURL: URL(fileURLWithPath: path),
                            touchesMarked: [.init(index: 1, time: 0.3, x: 0.5, y: 0.5), .init(index: 2, time: 1, x: 0.5, y: 0.5)], track: [])
                        try? player.history.library.saveReplayData(.init(summary: summary), for: item)
                        try? player.history.library.saveReplayEdit(.init(edit: .init(style: .none, intensity: 0), overlays: .init()), id: item.id, owner: nil)
                    }
                    Task { await player.history.retainVideo(URL(fileURLWithPath: path), for: item) }
                }
            }
        }
        if let path = SessionDesignReview.argument("--saved-shots-video") {
            let shots = player.shots
            Task {
                for (index, source) in [SavedJugglingResult.Source.recording, .gallery].enumerated() {
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
                    _ = try? await shots.add(video: copy, id: UUID(), owner: nil, source: source,
                                             completedAt: Date().addingTimeInterval(-Double(index) * 86400))
                }
            }
        }
        return player
    }
}
#endif
