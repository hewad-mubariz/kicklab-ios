import AVFoundation

/// Both exporters preserve the timeline chosen by the editor. MOV retains the
/// Photos full-frame-rate playback intent that MP4 drops for 120/240 fps media.
nonisolated enum VideoExportFormat {
    static func fileType(fps: Float) -> AVFileType { fps > 60 ? .mov : .mp4 }
    static func fileExtension(fps: Float) -> String { fps > 60 ? "mov" : "mp4" }
    static func playbackIntent() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
        item.dataType = kCMMetadataBaseDataType_UInt8 as String
        item.value = NSNumber(value: 1)
        return item
    }

    /// Shortest gap between kept frames when a clip is read at no more than `maxFrameRate`; zero keeps
    /// every frame. A frame is kept once this much time has passed since the last kept one, so the
    /// outline pass and the export keep the same frames of a 120 or 240 fps clip.
    static func spacing(maxFrameRate: Double, sourceFrameRate: Double) -> Double {
        guard maxFrameRate > 0, sourceFrameRate.isFinite, sourceFrameRate > maxFrameRate * 1.05 else { return 0 }
        return 1 / maxFrameRate - 0.5 / sourceFrameRate
    }
}

/// How a download is saved: the faster 1080p at up to 60 fps, or the clip's own resolution and frame rate.
nonisolated struct ExportChoice: Equatable, Sendable {
    /// Nil keeps the source size.
    let shortEdge: Int?
    /// Nil keeps every source frame.
    let maxFrameRate: Double?
    /// "1080p · 60 fps"
    let label: String
    var keepsEveryFrame: Bool { maxFrameRate == nil }

    static let fasterShortEdge = 1080
    static let fasterFrameRate = 60.0

    /// The faster choice, and the original when it differs, from the clip's metadata.
    static func choices(for info: VideoProcessingInfo) -> (faster: ExportChoice, original: ExportChoice?) {
        let width = Double(abs(info.size.width)), height = Double(abs(info.size.height))
        let short = Int(min(width, height).rounded()), long = Int(max(width, height).rounded())
        let fps: Double = info.fps.isFinite && info.fps > 0 ? info.fps : 30
        let fasterShort = short > 0 ? min(short, fasterShortEdge) : fasterShortEdge
        let scale: Double = short > 0 ? Double(fasterShort) / Double(short) : 1
        let fasterLong = short > 0 ? Int((Double(long) * scale).rounded()) : 1920
        let faster = ExportChoice(shortEdge: fasterShortEdge, maxFrameRate: fasterFrameRate,
                                  label: label(short: fasterShort, long: fasterLong, fps: min(fps, fasterFrameRate)))
        guard short > fasterShortEdge || fps > fasterFrameRate * 1.05 else { return (faster, nil) }
        return (faster, ExportChoice(shortEdge: nil, maxFrameRate: nil, label: label(short: short, long: long, fps: fps)))
    }

    /// "4K · 120 fps" for a saved video's size and frame rate.
    static func label(size: CGSize, fps: Double) -> String {
        let width = Double(abs(size.width)), height = Double(abs(size.height))
        return label(short: Int(min(width, height).rounded()), long: Int(max(width, height).rounded()), fps: fps)
    }

    private static func label(short: Int, long: Int, fps: Double) -> String {
        let size = long >= 3_840 ? "4K" : short >= 1_440 ? "\(short)p" : short >= 1_080 ? "1080p"
            : short >= 720 ? "720p" : "\(short)p"
        return "\(size) · \(Int(fps.rounded())) fps"
    }
}
