import Foundation

/// Durable editor input, separate from the history list. Keep the original counted
/// observations and touch clock, but never retain large per-frame mask buffers here.
nonisolated struct HistoryReplayData: Codable, Sendable {
    var version = 1
    let duration: Double
    let bestCombo: Int
    let personalBest: Int
    let sessionNumber: Int
    let frames: [StoredFrame]
    let touches: [[Double]]
    let framesUseCompositionClock: Bool

    init(summary: SessionSummary) {
        duration = summary.duration; bestCombo = summary.bestCombo
        personalBest = summary.personalBest; sessionNumber = summary.sessionNumber
        framesUseCompositionClock = summary.framesUseCompositionClock
        touches = summary.touchesMarked.map { [Double($0.index), $0.time, $0.x, $0.y] }
        frames = summary.track.map {
            var frame = $0
            frame.ballMask = nil
            return StoredFrame(frame)
        }
    }

    var isValid: Bool {
        version == 1 && duration.isFinite && duration > 0 && duration <= 86400
            && frames.count <= 2_000_000 && frames.allSatisfy { $0.isValid && $0.maskRect == nil }
            && touches.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isFinite)
                && $0[0] >= 0 && $0[0] < 1_000_000 && $0[0].rounded() == $0[0]
                && $0[1] >= 0 && $0[1] <= duration + 1 }
    }

    @MainActor func summary(item: HistorySession, videoURL: URL) -> SessionSummary {
        var value = SessionSummary.make(touches: item.touches, duration: duration, bestCombo: bestCombo,
            personalBest: personalBest, videoURL: videoURL,
            touchesMarked: touches.map { RecordedTouch(index: Int($0[0]), time: $0[1], x: $0[2], y: $0[3]) },
            track: frames.map(\.frame), sessionNumber: sessionNumber)
        // The first history-editor build saved an import's pre-presentation
        // summary, before this flag was set. Imported frames use this clock.
        value.framesUseCompositionClock = framesUseCompositionClock || item.source == .gallery
        value.needsVisualPreparation = true
        value.visualTrackIsPositionsOnly = true
        value.leaderboardTouchReview = item.touchReview
        value.savedBestStreak = item.source == .recording ? item.rankedProposal : nil
        return value
    }

    /// Old history entries have no editor sidecar. Prefer their saved touch clock
    /// when present; rebuilding a replay must never submit or change a saved score.
    @MainActor static func rebuilt(item: HistorySession, videoURL: URL, duration: Double,
                        frames: [RecordedFrame], detectedTouches: [RecordedTouch]) -> SessionSummary {
        let ordered = frames.sorted { $0.time < $1.time }
        let marks = item.touchTimesMS.map { times in
            times.enumerated().map { index, ms in
                let time = Double(ms) / 1000
                var low = 0, high = ordered.count
                while low < high {
                    let middle = (low + high) / 2
                    if ordered[middle].time < time { low = middle + 1 } else { high = middle }
                }
                let candidates = [low - 1, low].filter { ordered.indices.contains($0) }
                let nearest = candidates.map { ordered[$0] }.min { abs($0.time - time) < abs($1.time - time) }
                return RecordedTouch(index: index + 1, time: time, x: nearest?.smoothedX ?? 0.5, y: nearest?.smoothedY ?? 0.5)
            }
        } ?? detectedTouches
        var value = SessionSummary.make(touches: item.touches, duration: duration,
            bestCombo: item.rankedProposal?.count ?? item.touches, personalBest: item.touches,
            videoURL: videoURL, touchesMarked: marks, track: frames)
        value.framesUseCompositionClock = true
        value.needsVisualPreparation = true
        value.leaderboardTouchReview = item.touchReview
        value.savedBestStreak = item.source == .recording ? item.rankedProposal : nil
        return value
    }
}

/// Session-owned analysis survives cache eviction and app/OS updates. Its schema,
/// rather than the executable timestamp, determines whether it can be restored.
nonisolated struct HistoryReplayAnalysis: Codable, Sendable {
    var version = 1
    let frames: [StoredFrame]
    let prepared: Bool
    let positionsOnly: Bool
    let everyFrame: Bool

    init(summary: SessionSummary, prepared: Bool) {
        let render = summary.visualTrack ?? summary.track
        frames = render.map(StoredFrame.init)
        self.prepared = prepared
        positionsOnly = summary.visualTrackIsPositionsOnly
            || (render.contains(where: \.usesBallMasks) && render.allSatisfy { $0.ballMask == nil })
        everyFrame = !summary.framesUseCompositionClock || BallVisualRefiner.analysedEveryFrame(render)
    }

    var isValid: Bool { version == 1 && frames.count <= 2_000_000 && StoredFrame.validated(frames) }
    var quality: Int { !prepared ? 0 : positionsOnly ? 1 : everyFrame ? 3 : 2 }

    @MainActor func restoring(_ summary: SessionSummary) -> SessionSummary {
        var value = summary
        value.visualTrack = frames.map(\.frame)
        value.needsVisualPreparation = !prepared
        value.visualTrackIsPositionsOnly = positionsOnly
        return value
    }
}

nonisolated struct HistoryReplayContext: Sendable {
    let item: HistorySession
    let library: SessionHistoryLibrary
}

nonisolated struct HistoryReplayMotion: Codable, Sendable {
    var version = 1
    let key: String
    let timeline: StoredSurfaceTimeline
}

/// Unlike My style, this keeps exact per-touch runs and this video's overlay layout.
nonisolated struct HistoryReplayEdit: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let position: Int
        let ball: String
        let effect: String
    }
    var version = 1
    let style: MyStyle
    let intensity: Double
    let changes: [Change]
    let environment: String
    let scene: SceneSelection?
    let overlays: ExportOverlaySettings

    init(edit: SessionEditState, overlays: ExportOverlaySettings) {
        style = MyStyle(edit: edit); intensity = edit.intensity
        changes = edit.lookChanges.sorted { $0.key < $1.key }.map {
            Change(position: $0.key, ball: $0.value.ball.rawValue, effect: $0.value.effect.rawValue)
        }
        environment = edit.environment.rawValue; scene = edit.scene; self.overlays = overlays
    }

    var edit: SessionEditState {
        var value = style.edit(touchCount: 0)
        value.intensity = intensity.isFinite ? max(0, min(1, intensity)) : 0.7
        value.lookChanges = [:]
        for change in changes where change.position > 0 {
            if let ball = BallSkin(rawValue: change.ball), let effect = BallStyle(rawValue: change.effect) {
                value.lookChanges[change.position] = TouchLook(ball: ball, effect: effect)
            }
        }
        value.environment = EffectEnvironment(rawValue: environment) ?? .original
        value.scene = scene
        return value
    }
}

extension SessionHistoryLibrary {
    nonisolated private func editorURL(id: UUID, owner: UUID?, suffix: String) -> URL {
        root.appendingPathComponent(owner?.uuidString ?? "guest", isDirectory: true)
            .appendingPathComponent(id.uuidString + suffix)
    }

    nonisolated func saveReplayData(_ data: HistoryReplayData, for item: HistorySession) throws {
        guard data.isValid else { throw CocoaError(.coderInvalidValue) }
        try writeEditor(data, to: editorURL(id: item.id, owner: item.ownerID, suffix: ".replay.plist"), owner: item.ownerID)
    }

    nonisolated func replayData(for item: HistorySession) throws -> HistoryReplayData? {
        guard let data: HistoryReplayData = try readEditor(at: editorURL(id: item.id, owner: item.ownerID, suffix: ".replay.plist")) else { return nil }
        guard data.isValid else { throw CocoaError(.coderReadCorrupt) }
        return data
    }

    nonisolated func saveReplayEdit(_ edit: HistoryReplayEdit, id: UUID, owner: UUID?) throws {
        try writeEditor(edit, to: editorURL(id: id, owner: owner, suffix: ".edit.plist"), owner: owner)
    }

    nonisolated func replayEdit(for item: HistorySession) throws -> HistoryReplayEdit? {
        let edit: HistoryReplayEdit? = try readEditor(at: editorURL(id: item.id, owner: item.ownerID, suffix: ".edit.plist"))
        guard edit == nil || edit?.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return edit
    }

    nonisolated func replayAnalysis(for item: HistorySession) throws -> HistoryReplayAnalysis? {
        let value: HistoryReplayAnalysis? = try readEditor(at: editorURL(id: item.id, owner: item.ownerID, suffix: ".analysis.plist"))
        guard value == nil || value?.isValid == true else { throw CocoaError(.coderReadCorrupt) }
        return value
    }

    nonisolated func saveReplayAnalysis(_ value: HistoryReplayAnalysis, for item: HistorySession) throws {
        guard value.isValid else { throw CocoaError(.coderInvalidValue) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        try AccountDataGuard.write(owner: item.ownerID, root: root.deletingLastPathComponent()) {
            // A late raw-import save or a lighter effect must not replace a
            // completed dense/original-frame-rate preparation.
            if let previous = try? replayAnalysis(for: item), previous.quality > value.quality { return }
            try writeEditorBytes(data, to: editorURL(id: item.id, owner: item.ownerID, suffix: ".analysis.plist"), owner: item.ownerID)
        }
    }

    nonisolated func replayMotion(for item: HistorySession, key: String) throws -> BallSurfaceTimeline? {
        let value: HistoryReplayMotion? = try readEditor(at: editorURL(id: item.id, owner: item.ownerID, suffix: ".motion.plist"))
        guard let value, value.version == 1, value.key == key, value.timeline.isValid else { return nil }
        return value.timeline.timeline
    }

    nonisolated func saveReplayMotion(_ value: BallSurfaceTimeline, for item: HistorySession, key: String) throws {
        let stored = StoredSurfaceTimeline(value)
        guard stored.isValid else { throw CocoaError(.coderInvalidValue) }
        try writeEditor(HistoryReplayMotion(key: key, timeline: stored),
            to: editorURL(id: item.id, owner: item.ownerID, suffix: ".motion.plist"), owner: item.ownerID)
    }

    nonisolated func removeEditorData(for item: HistorySession) throws {
        try AccountDataGuard.write(owner: item.ownerID, root: root.deletingLastPathComponent()) {
            let marker = editorURL(id: item.id, owner: item.ownerID, suffix: ".editor-removed")
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker, options: [.atomic, .completeFileProtection])
            for suffix in [".replay.plist", ".edit.plist", ".analysis.plist", ".motion.plist"] {
                let url = editorURL(id: item.id, owner: item.ownerID, suffix: suffix)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    nonisolated private func writeEditor<T: Encodable>(_ value: T, to url: URL, owner: UUID?) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        try writeEditorBytes(data, to: url, owner: owner)
    }

    nonisolated private func writeEditorBytes(_ data: Data, to url: URL, owner: UUID?) throws {
        guard data.count <= 128 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try AccountDataGuard.write(owner: owner, root: root.deletingLastPathComponent()) {
            let id = String(url.lastPathComponent.prefix(36))
            let marker = url.deletingLastPathComponent().appendingPathComponent(id + ".editor-removed")
            guard !FileManager.default.fileExists(atPath: marker.path) else { throw CancellationError() }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var excluded = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        }
    }

    nonisolated private func readEditor<T: Decodable>(at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try PropertyListDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
