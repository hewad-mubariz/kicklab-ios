import CryptoKit
import Foundation

/// The capture folder is the source of truth, including after app relaunch.
/// A manifest is written last, only when video and geometry have finished saving.
nonisolated struct ShotRecording: Identifiable, Sendable {
    let directory: URL
    let date: Date
    let frameCount: Int
    let limitedFrames: Int
    let bytes: Int64
    var lastRollEstimateM: Float? = nil
    var peakRollingSpeedKMH: Float? = nil
    var id: String { directory.lastPathComponent }
    var video: URL { directory.appendingPathComponent("video.mov") }
}

nonisolated enum ShotRecordingStore {
    struct Library: Sendable {
        var recordings: [ShotRecording] = []
        var incompleteCount = 0
    }

    enum StoreError: LocalizedError {
        case incomplete, changed
        var errorDescription: String? {
            switch self {
            case .incomplete: "This shot did not finish saving its video and measurement data."
            case .changed: "The saved files could not be verified. The original recording has been kept."
            }
        }
    }

    private struct Manifest: Decodable {
        let schema: String
        let video: String
        let frames: String
        let recorded_frames: Int
        let limited_tracking_frames: Int
        let video_sha256: String
        let frames_sha256: String
        let recorded_at: Date?
        let roll_distance: String?
        let roll_distance_sha256: String?
        let roll_distance_last_estimate_m: Float?
        let roll_calibration_image: String?
        let roll_calibration_image_sha256: String?
        let roll_speed_peak_estimate_kmh: Float?
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotGeometryReviews", isDirectory: true)
    }

    private static func manifest(at directory: URL) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.schema == "kicklab.shot-geometry.v1",
              manifest.video == "video.mov", manifest.frames == "frames.jsonl",
              manifest.recorded_frames > 0 else { throw StoreError.incomplete }
        for name in ["video.mov", "frames.jsonl", "manifest.json"] {
            let values = try directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { throw StoreError.incomplete }
        }
        if manifest.roll_distance != nil || manifest.roll_distance_sha256 != nil {
            guard manifest.roll_distance == "roll-distance.jsonl", manifest.roll_distance_sha256 != nil else {
                throw StoreError.incomplete
            }
            let values = try directory.appendingPathComponent("roll-distance.jsonl")
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { throw StoreError.incomplete }
        }
        if let estimate = manifest.roll_distance_last_estimate_m {
            guard manifest.roll_distance != nil, estimate.isFinite, estimate >= 0 else { throw StoreError.incomplete }
        }
        if let speed = manifest.roll_speed_peak_estimate_kmh {
            guard manifest.roll_distance != nil, manifest.roll_calibration_image != nil,
                  speed.isFinite, speed >= 0, speed <= ShotRollSpeedEstimator.maximumSpeedMPS * 3.6
            else { throw StoreError.incomplete }
        }
        if manifest.roll_calibration_image != nil || manifest.roll_calibration_image_sha256 != nil {
            guard manifest.roll_distance != nil, manifest.roll_calibration_image == "roll-calibration.png",
                  manifest.roll_calibration_image_sha256 != nil else { throw StoreError.incomplete }
            let values = try directory.appendingPathComponent("roll-calibration.png")
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { throw StoreError.incomplete }
        }
        return manifest
    }

    static func load(root: URL = root) throws -> Library {
        guard FileManager.default.fileExists(atPath: root.path) else { return Library() }
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey],
            options: [.skipsHiddenFiles])
        var result = Library()
        for folder in folders {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                              .creationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            do {
                let data = try manifest(at: folder)
                let names = ["video.mov", "frames.jsonl", "manifest.json"] + (data.roll_distance.map { [$0] } ?? []) + (data.roll_calibration_image.map { [$0] } ?? [])
                let bytes = try names.reduce(Int64(0)) {
                    $0 + Int64(try folder.appendingPathComponent($1)
                        .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
                result.recordings.append(ShotRecording(directory: folder,
                    date: data.recorded_at ?? values.creationDate ?? .distantPast,
                    frameCount: data.recorded_frames, limitedFrames: data.limited_tracking_frames,
                    bytes: bytes, lastRollEstimateM: data.roll_distance_last_estimate_m,
                    peakRollingSpeedKMH: data.roll_speed_peak_estimate_kmh))
            } catch { result.incompleteCount += 1 }
        }
        result.recordings.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return result
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A local ZIP snapshot; nothing is uploaded by NSFileCoordinator.
    /// Copy inside its accessor because the system removes the snapshot afterward.
    static func export(_ recording: ShotRecording, to destination: URL) throws -> URL {
        let data = try manifest(at: recording.directory)
        guard try hash(recording.video) == data.video_sha256,
              try hash(recording.directory.appendingPathComponent("frames.jsonl")) == data.frames_sha256
        else { throw StoreError.changed }
        if let expected = data.roll_distance_sha256 {
            guard try hash(recording.directory.appendingPathComponent("roll-distance.jsonl")) == expected else {
                throw StoreError.changed
            }
        }
        if let expected = data.roll_calibration_image_sha256 {
            guard try hash(recording.directory.appendingPathComponent("roll-calibration.png")) == expected else {
                throw StoreError.changed
            }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = destination.appendingPathComponent("Power-Shot-\(recording.id).zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: recording.directory, options: .forUploading,
                                       error: &coordinationError) { snapshot in
            do { try FileManager.default.copyItem(at: snapshot, to: output) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError as NSError? { throw error }
        guard FileManager.default.fileExists(atPath: output.path) else { throw StoreError.incomplete }
        return output
    }

    /// Rotation is for playback only; the original sensor movie is never rewritten.
    static func previewRotation(_ recording: ShotRecording) throws -> Int {
        let handle = try FileHandle(forReadingFrom: recording.directory.appendingPathComponent("frames.jsonl"))
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 131_072) ?? Data()
        for line in prefix.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["tracking_state"] as? String == "normal",
                  let pose = row["world_from_camera"] as? [[Double]], pose.count == 4,
                  pose.allSatisfy({ $0.count == 4 }) else { continue }
            let x = -pose[1][0], y = -pose[1][1]
            guard x.isFinite, y.isFinite, hypot(x, y) >= 0.25 else { continue }
            let directions = [y, x, -y, -x]
            return (directions.indices.max { directions[$0] < directions[$1] } ?? 0) * 90
        }
        return 0
    }
}
