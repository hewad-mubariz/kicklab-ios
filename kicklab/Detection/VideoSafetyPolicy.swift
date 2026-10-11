import AVFoundation
import Foundation

/// Input validity and disk-space checks shared by capture, imports and exports.
/// Juggling has no fixed duration, frame-count or retained-mask memory cutoff.
nonisolated enum VideoSafetyPolicy {
    static let storageReserve: Int64 = 512 * 1_024 * 1_024

    enum Failure: LocalizedError {
        case storage, invalidVideo, analysis
        var errorDescription: String? {
            switch self {
            case .storage: "There isn’t enough free storage to safely save this video. Free some space and try again."
            case .invalidVideo: "This video has no usable duration or video track. Choose another video."
            case .analysis: "Ball tracking was interrupted. Please try processing the video again. No score was submitted."
            }
        }
    }

    static func validate(duration: Double) throws {
        guard duration.isFinite, duration > 0 else { throw Failure.invalidVideo }
    }
    @discardableResult
    static func validateInput(_ source: URL) async throws -> Double {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw Failure.invalidVideo }
        let duration = try await asset.load(.duration).seconds
        try validate(duration: duration)
        return duration
    }
    static func requireSpace(bytes: Int64, available: Int64) throws {
        guard bytes >= 0, available >= storageReserve,
              bytes <= available - storageReserve else { throw Failure.storage }
    }
    static func requireSpace(bytes: Int64, at directory: URL = .temporaryDirectory) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) else { throw Failure.storage }
        try requireSpace(bytes: bytes, available: available)
    }
    static func requireCopySpace(_ source: URL, copies: Int64 = 1) throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 0, copies > 0, Int64(size) <= Int64.max / copies else { throw Failure.storage }
        try requireSpace(bytes: Int64(size) * copies)
    }
    static func requireExportSpace(duration: Double) throws {
        // Covers silent output, muxed output and a temporary scene at 14 Mbps,
        // with ample headroom. Original videos are never evicted to make space.
        guard duration.isFinite, duration > 0, duration < 86_400 else { throw Failure.invalidVideo }
        try requireSpace(bytes: Int64(ceil(duration * 6_000_000)))
    }

    /// Only regenerable export outputs, never imports, recordings or history.
    /// Run once at launch; previous-process files cannot belong to an active job.
    static func cleanExpiredExports(in directory: URL = .temporaryDirectory, now: Date = Date()) throws {
        let prefixes = ["juggledude-render-", "juggledude-edited-", "power-shot-"]
        for file in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) {
            guard prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }),
                  ["mp4", "mov"].contains(file.pathExtension) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > 86_400 else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
}
