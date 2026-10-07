import AVFoundation
import CoreMedia

/// HDR composition playback can fail on devices that still decode the source.
/// Build one SDR editing proxy with the same exporter, retain the original for
/// the final export, and reuse the proxy when navigating back from Save & Share.
actor EffectPreviewCache {
    static let shared = EffectPreviewCache()
    private var pending: [URL: Task<URL, Error>] = [:]

    func preparedURL(for source: URL) async throws -> URL {
        if let task = pending[source] { return try await task.value }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return source }
        let descriptions = try await track.load(.formatDescriptions)
        let isHDR = descriptions.contains { description in
            let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? ""
            return transfer.contains("HLG") || transfer.contains("2084") || transfer.contains("PQ")
        }
        guard isHDR else { return source }
        let task = Task.detached(priority: .userInitiated) {
            try await BallStyleBurnIn.render(source: source, track: [], style: .none, intensity: 0, shortEdge: 1080)
        }
        pending[source] = task
        do { return try await task.value }
        catch { pending[source] = nil; throw error }
    }
}
