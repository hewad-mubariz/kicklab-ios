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

/// Video auto exposure keeps the shutter near the frame duration and spends extra
/// light on lower ISO: 8–17 ms was measured both indoors and outdoors. That smears
/// a juggled ball's edges and the panel texture source spin depends on. Keep auto
/// exposure but cap its shutter, relaxing only when the sensor runs out of gain.
nonisolated struct CaptureExposureCap {
    /// Fastest first. Past the last step the camera's own limit applies.
    static let steps: [Double] = [1.0 / 500, 1.0 / 250, 1.0 / 120]
    private(set) var level = 0
    private var vote = 0
    private var lastCheck = -Double.infinity
    private var applied: CMTime?
    /// Video auto exposure may stop short of the format's maximum ISO. The gain
    /// it reached while still too dark bounds later tightening, so the cap
    /// cannot step back into darkness and pump.
    private var ceiling = Double.infinity

    var seconds: Double? { level < Self.steps.count ? Self.steps[level] : nil }

    /// One step per second of agreeing readings, so a passing shadow cannot pump exposure.
    /// `exposure` is the shutter in use; tightening must leave ISO headroom.
    mutating func update(iso: Double, maxISO: Double, exposure: Double, offset: Double) -> Bool {
        guard iso.isFinite, iso > 0, maxISO.isFinite, maxISO > 0,
              exposure.isFinite, exposure > 0, offset.isFinite else { return false }
        let limit = min(maxISO, ceiling)
        let starved = level < Self.steps.count && offset < -0.5 && (iso >= 0.9 * limit || offset < -0.7)
        let roomy = level > 0 && iso * exposure / Self.steps[level - 1] <= 0.5 * limit && abs(offset) < 0.3
        let direction = starved ? 1 : roomy ? -1 : 0
        vote = direction == 0 || vote.signum() == -direction ? direction : vote + direction
        guard abs(vote) >= 2 else { return false }
        if vote > 0 { ceiling = min(ceiling, iso) }
        level += vote.signum(); vote = 0
        return true
    }

    /// captureQueue, every delivered frame. Re-applies the cap after a format change resets it.
    mutating func observe(_ device: AVCaptureDevice, at time: Double) {
        guard time.isFinite, time - lastCheck >= 0.5 || time < lastCheck else { return }
        lastCheck = time
        let changed = update(iso: Double(device.iso), maxISO: Double(device.activeFormat.maxISO),
                             exposure: device.exposureDuration.seconds, offset: Double(device.exposureTargetOffset))
        let target = seconds.map { Self.duration($0, format: device.activeFormat) } ?? .invalid
        // A format change restores the longer default; the device may round ours slightly.
        let reset = target.isValid && device.activeMaxExposureDuration.seconds > target.seconds * 1.1
        guard changed || applied == nil || reset else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeMaxExposureDuration = target
        device.unlockForConfiguration()
        applied = target
    }

    static func duration(_ seconds: Double, format: AVCaptureDevice.Format) -> CMTime {
        let value = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        return CMTimeMaximum(format.minExposureDuration, CMTimeMinimum(format.maxExposureDuration, value))
    }
}

nonisolated struct CaptureCadenceSnapshot: Codable, Sendable {
    /// Optional for older reports. These are periodic device readings, not
    /// frame-exact exposure metadata; they must not drive replacement rendering.
    struct Optics: Codable, Sendable {
        let recordingSeconds: Double
        let exposureSeconds: Double
        let iso: Double
        let exposureTargetOffset: Double
        /// The shutter cap in force; nil when the camera's own limit applies.
        var exposureCapSeconds: Double? = nil
    }
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
    var optics: Optics?
}
