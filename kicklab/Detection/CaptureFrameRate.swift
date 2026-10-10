import AVFoundation

nonisolated enum CaptureFrameRate {
    struct Candidate {
        let width: Int
        let height: Int
        let ranges: [ClosedRange<Double>]
        let standardPixelFormat: Bool
    }
    struct Selection {
        let index: Int
        let fps: Int
    }

    /// Prefer 720p; allow 1080p only if the lens has no 720p format at this rate.
    /// Never select 4K/high-resolution formats just to obtain 60 fps.
    static func select(_ candidates: [Candidate]) -> Selection? {
        for fps in [60, 30] {
            let eligible = candidates.indices.filter { i in
                let c = candidates[i]
                return min(c.width, c.height) >= 720 && max(c.width, c.height) <= 1920
                    && abs(Double(max(c.width, c.height)) / Double(min(c.width, c.height)) - 16.0 / 9) < 0.01
                    && c.ranges.contains { $0.contains(Double(fps)) }
            }
            if let index = eligible.min(by: { a, b in
                let x = candidates[a], y = candidates[b]
                if x.width * x.height != y.width * y.height { return x.width * x.height < y.width * y.height }
                if x.standardPixelFormat != y.standardPixelFormat { return x.standardPixelFormat }
                return a < b
            }) { return Selection(index: index, fps: fps) }
        }
        return nil
    }

    static func configure(_ device: AVCaptureDevice) throws -> CaptureCadenceSnapshot {
        let formats = device.formats
        let candidates = formats.map { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return Candidate(width: Int(d.width), height: Int(d.height),
                ranges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate },
                standardPixelFormat: type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        guard let choice = select(candidates) else {
            throw NSError(domain: "KickLabCapture", code: 60,
                userInfo: [NSLocalizedDescriptionKey: "No supported 720p/1080p recording format at 30 or 60 fps."])
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = formats[choice.index]
        if #available(iOS 18.0, *), device.activeFormat.isAutoVideoFrameRateSupported {
            device.isAutoVideoFrameRateEnabled = false
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(choice.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        var result = CaptureCadenceSnapshot()
        result.selectedFPS = choice.fps
        result.width = candidates[choice.index].width
        result.height = candidates[choice.index].height
        result.position = device.position == .front ? "front" : "back"
        return result
    }
}

nonisolated struct CaptureCadenceSnapshot: Codable, Sendable {
    var requestedFPS = 60
    var selectedFPS = 0
    var width = 0
    var height = 0
    var position = "unknown"
    var receivedFrames = 0
    var writtenFrames = 0
    var writerDrops = 0
    var captureDrops = 0
    var analysisOffered = 0
    var analysisThrottled = 0
    var analysisReplaced = 0
    var analysedFrames = 0
    var duration = 0.0
}
