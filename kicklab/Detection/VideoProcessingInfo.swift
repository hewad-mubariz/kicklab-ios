import AVFoundation
import Foundation

/// Reads the source's metadata, never its frames. This is an explanation of
/// likely workload, not an estimate of how long a particular phone will take.
nonisolated struct VideoProcessingInfo: Sendable {
    let size: CGSize
    let fps: Double
    let duration: Double

    static func load(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoSafetyPolicy.Failure.invalidVideo
        }
        let duration = try await asset.load(.duration).seconds
        let fps = try await track.load(.nominalFrameRate)
        // Optional display metadata must not prevent an otherwise valid import.
        let size = (try? await track.load(.naturalSize)) ?? .zero
        try Task.checkCancellation()
        return Self(size: size, fps: Double(fps), duration: duration)
    }

    private var longEdge: Double { max(abs(size.width), abs(size.height)) }
    private var highResolution: Bool { longEdge >= 2_560 }
    private var highFrameRate: Bool { fps.isFinite && fps >= 50 }

    var resolutionLabel: String? {
        guard longEdge.isFinite, longEdge > 0 else { return nil }
        if longEdge >= 7_680 { return "8K" }
        if longEdge >= 3_840 { return "4K" }
        return "\(Int(abs(size.width).rounded())) × \(Int(abs(size.height).rounded()))"
    }

    var timingLabel: String {
        var parts: [String] = []
        if fps.isFinite, fps > 0 { parts.append("\(Int(fps.rounded())) fps") }
        if duration.isFinite, duration > 0 { parts.append("\(Int(duration.rounded()))s") }
        return parts.joined(separator: " · ")
    }

    var processingNote: String? {
        if highResolution || highFrameRate || duration >= 60 {
            return String(localized: "May take a little longer", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
        return nil
    }
}
