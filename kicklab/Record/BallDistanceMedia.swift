import AVFoundation
import Foundation

nonisolated enum BallDistanceMedia {
    /// Save an upright playback copy. Original sensor pixels, camera poses,
    /// calibration photo and distance observations remain together and untouched.
    static func uprightCopy(of recording: ShotRecording) async throws -> URL {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            recording.directory.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
        guard let videoHash = manifest["video_sha256"] as? String,
              let frameHash = manifest["frames_sha256"] as? String,
              try ShotRecordingStore.hash(recording.video) == videoHash,
              try ShotRecordingStore.hash(recording.directory.appendingPathComponent("frames.jsonl")) == frameHash else {
            throw ShotRecordingStore.StoreError.changed
        }
        let rotation = try ShotRecordingStore.previewRotation(recording)
        let asset = AVURLAsset(url: recording.video)
        let duration = try await asset.load(.duration)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShotRecordingStore.StoreError.incomplete
        }
        let size = try await source.load(.naturalSize)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ShotRecordingStore.StoreError.incomplete }
        let range = CMTimeRange(start: .zero, duration: duration)
        try video.insertTimeRange(range, of: source, at: .zero)
        var transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        transform.tx = -bounds.minX; transform.ty = -bounds.minY
        video.preferredTransform = transform
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BallDistanceReplay", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(UUID().uuidString + ".mov")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ShotRecordingStore.StoreError.incomplete
        }
        do { try await exporter.export(to: output, as: .mov); try Task.checkCancellation(); return output }
        catch { try? FileManager.default.removeItem(at: output); throw error }
    }

    static func summary(video: URL, duration: Double, frames: [RecordedFrame]) -> SessionSummary {
        var value = SessionSummary(touches: 0, duration: duration, bestCombo: 0,
            maxHeightMeters: nil, avgHeightMeters: nil, personalBest: 0, videoURL: video,
            touchesMarked: [], track: frames, drops: 0, consistency: 0, touchTimeline: [])
        value.framesUseCompositionClock = true
        return value
    }
}
