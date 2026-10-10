import AVFoundation

/// Source timestamps remain authoritative for ball detections, trails and distance labels.
nonisolated struct ShotReplayClock: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case original, ramp, freeze }
    var mode: Mode = .original
    var strike = 0.0
    var duration = 1.0
    static let hold = 0.65
    var holdDuration = Self.hold
    var selectedRange: ShotSourceRange?
    var rate = 0.25
    var smooth = false
    var slowStart: Double { selectedRange?.start ?? max(0, strike - 0.1) }
    var slowEnd: Double { selectedRange?.end ?? min(duration, strike + 0.18) }
    var slowLength: Double { max(0, slowEnd - slowStart) }
    var outputDuration: Double { outputTime(for: duration) }
    var isOriginal: Bool { mode == .original }

    init(mode: Mode = .original, strike: Double = 0, duration: Double = 1) {
        self.mode = mode
        self.duration = max(0.001, duration)
        self.strike = min(max(0, strike), max(0, duration - 0.001))
    }
    init(settings: ShotCameraSettings, track: BallEffectTrack, flight: ShotFlight?, duration: Double) {
        self.init(mode: settings.style == .ramp ? .ramp : settings.style == .freeze ? .freeze : .original,
                  strike: settings.style == .freeze ? settings.freezeFrame ?? settings.strikeTime(track: track, flight: flight) : settings.strikeTime(track: track, flight: flight), duration: duration)
        if mode == .ramp {
            selectedRange = settings.range(for: .ramp, strike: strike, duration: duration)
            rate = min(1, max(0.25, settings.rampRate))
            smooth = settings.smoothRamp
        }
        if mode == .freeze { holdDuration = min(3, max(0.2, settings.freezeHold)) }
    }
    struct Segment: Equatable, Sendable {
        var start: Double
        var end: Double
        var rate: Double
        var length: Double { end - start }
    }
    /// A short piecewise transition shared by AVComposition and both clock directions.
    /// Integrate the same segment rates rather than estimating a different playback curve.
    var segments: [Segment] {
        guard mode == .ramp, slowLength > 0.00001, rate < 1 else { return [] }
        guard smooth else { return [Segment(start: slowStart, end: slowEnd, rate: rate)] }
        let edge = min(0.16, slowLength * 0.25)
        var result: [Segment] = []
        for i in 0..<6 {
            let t = (Double(i) + 0.5) / 6
            let eased = t * t * (3 - 2 * t)
            result.append(Segment(start: slowStart + edge * Double(i) / 6,
                                  end: slowStart + edge * Double(i + 1) / 6, rate: 1 + (rate - 1) * eased))
        }
        result.append(Segment(start: slowStart + edge, end: slowEnd - edge, rate: rate))
        for i in 0..<6 {
            let t = (Double(i) + 0.5) / 6
            let eased = t * t * (3 - 2 * t)
            result.append(Segment(start: slowEnd - edge + edge * Double(i) / 6,
                                  end: slowEnd - edge + edge * Double(i + 1) / 6, rate: rate + (1 - rate) * eased))
        }
        return result
    }
    func outputTime(for source: Double) -> Double {
        let t = min(duration, max(0, source))
        switch mode {
        case .original: return t
        case .ramp: return t + segments.reduce(0) { $0 + min($1.length, max(0, t - $1.start)) * (1 / $1.rate - 1) }
        case .freeze: return t + (t > strike ? holdDuration : 0)
        }
    }
    func sourceTime(for output: Double) -> Double {
        let t = max(0, output)
        switch mode {
        case .original: return min(duration, t)
        case .ramp:
            var extra = 0.0
            for segment in segments {
                let start = segment.start + extra
                if t < start { return min(duration, t - extra) }
                if t <= start + segment.length / segment.rate { return segment.start + (t - start) * segment.rate }
                extra += segment.length * (1 / segment.rate - 1)
            }
            return min(duration, t - extra)
        case .freeze:
            if t < strike { return t }
            if t < strike + holdDuration { return strike }
            return min(duration, t - holdDuration)
        }
    }

    /// Retime the existing video and audio, with silence during a freeze.
    /// No extra model or generated intermediate footage is involved.
    func asset(source: URL) async throws -> AVAsset {
        let original = AVURLAsset(url: source)
        // AVAssetTrack references its parent weakly; retain it until all segments are inserted.
        defer { withExtendedLifetime(original) {} }
        guard !isOriginal else { return original }
        guard let video = try await original.loadTracks(withMediaType: .video).first else {
            throw ShotEffectExporter.Failure.noVideo
        }
        let audio = try await original.loadTracks(withMediaType: .audio).first
        let audioRange = try await audio?.load(.timeRange) ?? .zero
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ShotEffectExporter.Failure.writer("Couldn’t prepare the replay.")
        }
        picture.preferredTransform = try await video.load(.preferredTransform)
        let sound = audio.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        func stamp(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_800_000_000) }
        func insert(_ start: Double, _ length: Double, at target: Double, includeSound: Bool = true) throws {
            guard length > 0.00001 else { return }
            let range = CMTimeRange(start: stamp(start), duration: stamp(length))
            try picture.insertTimeRange(range, of: video, at: stamp(target))
            if includeSound, let sound, let audio {
                let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if available.duration.seconds > 0 {
                    try sound.insertTimeRange(available, of: audio, at: stamp(target + available.start.seconds - start))
                }
            }
        }
        switch mode {
        case .original: break
        case .ramp:
            try insert(0, duration, at: 0)
            // Scale from the end so earlier edits do not shift later source ranges.
            for segment in segments.reversed() {
                composition.scaleTimeRange(CMTimeRange(start: stamp(segment.start), duration: stamp(segment.length)),
                                           toDuration: stamp(segment.length / segment.rate))
            }
        case .freeze:
            try insert(0, strike, at: 0)
            let index = try await ShotSourceFrames.load(source)
            let frameLength = min(duration - strike, index.frameDuration(at: strike))
            // Start just inside the selected frame, avoiding rounding onto its predecessor.
            let epsilon = min(0.000001, frameLength / 100)
            try insert(strike + epsilon, frameLength - epsilon, at: strike, includeSound: false)
            picture.scaleTimeRange(CMTimeRange(start: stamp(strike), duration: stamp(frameLength - epsilon)),
                                   toDuration: stamp(holdDuration))
            try insert(strike, duration - strike, at: strike + holdDuration)
        }
        return composition
    }
}
