#if DEBUG && TOUCH_COUNTING_DEBUG
import Foundation

/// Opt-in evidence from the actual preview/export path; never drives preparation.
enum RFEffectsRoutingAudit {
    private static func folder() throws -> URL {
        let root = URL.documentsDirectory.appendingPathComponent("RFEffectsRoutingAudit")
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(folder.lastPathComponent.utf8).write(to: root.appendingPathComponent("latest.txt"), options: .atomic)
        return folder
    }
    private static func marks(_ touches: [RecordedTouch]) -> [[Double]] {
        touches.map { [Double($0.index), $0.time, $0.x, $0.y] }
    }
    static func prepared(original: SessionSummary, result: SessionSummary) {
        guard ProcessInfo.processInfo.arguments.contains("--rf-effects-audit") else { return }
        do {
            let url = try folder()
            let track = try SessionAnalysisStore.frameData(result.renderTrack)
            try track.write(to: url.appendingPathComponent("visual-track.plist"))
            let report: [String: Any] = ["event": "prepared", "positions_only": result.visualTrackIsPositionsOnly, "source_sha256": try SessionAnalysisStore.sourceDigest(original.videoURL),
                "input_count": original.touches, "output_count": result.touches,
                "input_touches": marks(original.touchesMarked), "output_touches": marks(result.touchesMarked),
                "input_track_frames": original.track.count, "output_track_frames": result.renderTrack.count,
                "output_mask_frames": result.renderTrack.filter { $0.ballMask != nil }.count,
                "visual_track_sha256": SessionAnalysisStore.digest(track), "needs_preparation": result.needsVisualPreparation]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: url.appendingPathComponent("report.json"))
        } catch { NSLog("RF effects routing audit: %@", error.localizedDescription) }
    }
    static func exported(source: URL, output: URL, track: [RecordedFrame], edit: SessionEditState,
                         count: Int, touches: [RecordedTouch]) {
        guard ProcessInfo.processInfo.arguments.contains("--rf-effects-audit") else { return }
        do {
            let url = try folder(), data = try SessionAnalysisStore.frameData(track)
            try data.write(to: url.appendingPathComponent("export-track.plist"))
            let report: [String: Any] = ["event": "exported", "source_sha256": try SessionAnalysisStore.sourceDigest(source),
                "style": edit.style.rawValue, "skin": edit.ballSkin.rawValue, "intensity": edit.intensity,
                "count": count, "touches": marks(touches), "track_frames": track.count,
                "track_sha256": SessionAnalysisStore.digest(data), "output_path": output.path]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: url.appendingPathComponent("report.json"))
        } catch { NSLog("RF effects export audit: %@", error.localizedDescription) }
    }
}
#endif
