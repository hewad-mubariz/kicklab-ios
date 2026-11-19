import AVFoundation
import CoreMedia

/// Play the source first. A neutral SDR movie is only needed for incompatible
/// playback, and belongs to the source bytes rather than a particular effect.
actor EffectPreviewCache {
    static let shared = EffectPreviewCache()
    private let movies = PreviewMovieCache(
        folder: URL.cachesDirectory.appendingPathComponent("EffectPreview-v1", isDirectory: true),
        policy: "neutral-sdr-1080-source-cadence-v1-os\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)",
        render: { source in
            // Hold a lease until native rendering actually stops on cancellation.
            let access = try VideoStorageAccess.beginRead()
            defer { access.release() }
            return try await BallStyleBurnIn.render(source: source, track: [], style: .none, intensity: 0, shortEdge: 1080)
        }, validate: { url in
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable),
                  try await asset.loadTracks(withMediaType: .video).first != nil else { return false }
            let duration = try await asset.load(.duration).seconds
            return duration.isFinite && duration > 0
        })

    func releaseCachedResults() async throws {
        guard await !movies.isBusy else { throw VideoStorageMaintenance.Failure.busy }
        await movies.releaseMemory()
    }

    func previewURL(for source: URL) async throws -> URL {
        let access = try VideoStorageAccess.beginRead()
        defer { access.release() }
        return try await movies.existing(for: source) ?? source
    }

    func compatibilityURL(for source: URL) async throws -> URL {
        let access = try VideoStorageAccess.beginRead()
        defer { access.release() }
        return try await movies.converted(source)
    }

    /// Existing scene/export callers keep their explicit SDR preparation policy.
    func preparedURL(for source: URL) async throws -> URL {
        #if DEBUG
        await ImportFlowAudit.increment("proxy_requests")
        #endif
        let access = try VideoStorageAccess.beginRead()
        defer { access.release() }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return source }
        let descriptions = try await track.load(.formatDescriptions)
        let isHDR = descriptions.contains { description in
            let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? ""
            return transfer.contains("HLG") || transfer.contains("2084") || transfer.contains("PQ")
        }
        return isHDR ? try await compatibilityURL(for: source) : source
    }
}
