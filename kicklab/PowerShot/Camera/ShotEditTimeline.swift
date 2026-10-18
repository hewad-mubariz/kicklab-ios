import AVFoundation

/// How the saved video's clock walks through the recording once the camera track's time moves
/// (Speed Ramp, Freeze + Path, Instant Replay) are applied. Source timestamps stay authoritative
/// for the ball track; this only decides which source moment each output moment shows.
nonisolated struct ShotEditTimeline: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Normal or slowed playback. Rate is source seconds per output second.
        case play(rate: Double)
        /// One source frame held still.
        case hold
        /// Fast reverse, for the replay's rewind.
        case rewind
    }

    struct Segment: Equatable, Sendable {
        var kind: Kind
        /// For a rewind, `from` is later than `to`.
        var from: Double
        var to: Double
        var outputStart: Double
        var outputLength: Double
        var clip: UUID?
        /// The slow pass of an Instant Replay (after its rewind).
        var isReplay = false
        var outputEnd: Double { outputStart + outputLength }
    }

    struct Location: Equatable, Sendable {
        var source: Double
        var segment: Segment
        /// 0 – 1 through the segment, and seconds into it.
        var progress: Double
        var elapsed: Double
    }

    static let rewindSpeed = 4.5
    let duration: Double
    private(set) var segments: [Segment] = []
    var outputDuration: Double { segments.last?.outputEnd ?? duration }
    var isOriginal: Bool { segments.allSatisfy { $0.kind == .play(rate: 1) } }

    init(duration: Double = 1) {
        self.duration = max(0.001, duration)
        segments = [Segment(kind: .play(rate: 1), from: 0, to: self.duration, outputStart: 0, outputLength: self.duration)]
    }

    init(track: ShotCameraTrack, duration: Double, frameDuration: Double = 1.0 / 60) {
        self.duration = max(0.001, duration)
        var result: [Segment] = []
        var cursor = 0.0, out = 0.0
        func add(_ kind: Kind, _ from: Double, _ to: Double, length: Double, clip: UUID? = nil, replay: Bool = false) {
            guard length > 0.0005 else { return }
            result.append(Segment(kind: kind, from: from, to: to, outputStart: out, outputLength: length, clip: clip, isReplay: replay))
            out += length
        }
        func play(to target: Double) {
            let t = min(self.duration, max(cursor, target))
            add(.play(rate: 1), cursor, t, length: t - cursor)
            cursor = t
        }
        for clip in track.clips where clip.move.retimes {
            let a = min(self.duration, max(cursor, clip.start)), b = min(self.duration, max(a, clip.end))
            switch clip.move {
            case .ramp, .slowmo:
                play(to: a)
                let rate = min(1, max(0.1, clip.settings.rate))
                if clip.settings.smooth {
                    // Ease in and out over short steps, as one continuous playback curve.
                    let edge = min(0.16, (b - a) * 0.25)
                    func ease(_ lo: Double, _ hi: Double, from: Double, to: Double) {
                        for i in 0..<6 {
                            let t = (Double(i) + 0.5) / 6, eased = t * t * (3 - 2 * t)
                            let r = from + (to - from) * eased
                            let s0 = lo + (hi - lo) * Double(i) / 6, s1 = lo + (hi - lo) * Double(i + 1) / 6
                            add(.play(rate: r), s0, s1, length: (s1 - s0) / r, clip: clip.id)
                        }
                    }
                    ease(a, a + edge, from: 1, to: rate)
                    add(.play(rate: rate), a + edge, b - edge, length: (b - a - 2 * edge) / rate, clip: clip.id)
                    ease(b - edge, b, from: rate, to: 1)
                } else {
                    add(.play(rate: rate), a, b, length: (b - a) / rate, clip: clip.id)
                }
                cursor = b
            case .freeze:
                play(to: a)
                add(.hold, a, a, length: min(3, max(0.2, clip.settings.hold)), clip: clip.id)
            case .arc:
                play(to: a)
                add(.hold, a, a, length: min(4, max(0.5, clip.settings.hold)), clip: clip.id)
            case .replay:
                play(to: b)
                add(.rewind, b, a, length: (b - a) / Self.rewindSpeed, clip: clip.id)
                let rate = min(1, max(0.1, clip.settings.rate))
                add(.play(rate: rate), a, b, length: (b - a) / rate, clip: clip.id, replay: true)
                cursor = b
            default: break
            }
        }
        play(to: self.duration)
        segments = result.isEmpty ? [Segment(kind: .play(rate: 1), from: 0, to: self.duration, outputStart: 0, outputLength: self.duration)] : result
    }

    func locate(_ output: Double) -> Location {
        let t = min(outputDuration, max(0, output))
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].outputStart <= t { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        let elapsed = min(s.outputLength, max(0, t - s.outputStart))
        let progress = s.outputLength > 0 ? elapsed / s.outputLength : 1
        let source: Double
        switch s.kind {
        case .play: source = s.from + (s.to - s.from) * progress
        case .hold: source = s.from
        case .rewind: source = s.from + (s.to - s.from) * progress
        }
        return Location(source: min(duration, max(0, source)), segment: s, progress: progress, elapsed: elapsed)
    }

    func sourceTime(for output: Double) -> Double { locate(output).source }

    /// The first time the saved video shows a source moment (a replay shows it again later).
    func outputTime(for source: Double) -> Double {
        let t = min(duration, max(0, source))
        for s in segments where !s.isReplay {
            switch s.kind {
            case .play where t >= s.from - 0.00001 && t <= s.to + 0.00001:
                return s.outputStart + (s.to > s.from ? (t - s.from) / (s.to - s.from) * s.outputLength : 0)
            case .hold where abs(t - s.from) < 0.00001:
                return s.outputStart
            default: continue
            }
        }
        return min(outputDuration, t)
    }

    /// Retimes the video (and its sound, except during holds and rewinds) without re-encoding
    /// or inventing frames. Rewinds are built from individual source frames in reverse.
    /// `smooth` holds slowed stretches already rendered with in-between frames; they replace the
    /// stretched (repeated) frames of those stretches. The sound is slowed as before.
    @concurrent func asset(source: URL, smooth: ShotSlowMotion? = nil) async throws -> AVAsset {
        let original = AVURLAsset(url: source)
        defer { withExtendedLifetime(original) {} }
        guard !isOriginal else { return original }
        guard let video = try await original.loadTracks(withMediaType: .video).first else {
            throw ShotEffectExporter.Failure.noVideo
        }
        let frames = try await ShotSourceFrames.load(source)
        let audio = try await original.loadTracks(withMediaType: .audio).first
        let audioRange = try await audio?.load(.timeRange) ?? .zero
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ShotEffectExporter.Failure.writer("Couldn’t prepare the replay.")
        }
        picture.preferredTransform = try await video.load(.preferredTransform)
        let sound = audio.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        // A track needs its asset alive while the composition is built, like the original's above.
        let smoothAsset = smooth.flatMap { $0.source == source ? AVURLAsset(url: $0.movie) : nil }
        defer { withExtendedLifetime(smoothAsset) {} }
        var smoothVideo: AVAssetTrack?, smoothRange = CMTimeRange.zero
        if let smoothAsset {
            smoothVideo = try await smoothAsset.loadTracks(withMediaType: .video).first
            smoothRange = try await smoothVideo?.load(.timeRange) ?? .zero
        }
        func stamp(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_800_000_000) }
        /// Inserts source [from, from + length) at `at` and stretches it to `output` seconds. A slowed
        /// stretch with smooth in-between frames takes its pictures from those instead.
        func place(_ from: Double, _ length: Double, at: Double, output: Double, withSound: Bool) throws {
            guard length > 0.000001, output > 0.000001 else { return }
            let range = CMTimeRange(start: stamp(from), duration: stamp(length))
            if output > length + 0.000001, let smoothVideo,
               let clip = smooth?.clip(for: ShotSlowMotion.Stretch(from: from, to: from + length, length: output)),
               case let available = CMTimeRangeGetIntersection(CMTimeRange(start: stamp(clip.start), duration: stamp(clip.length)), otherRange: smoothRange),
               available.duration.seconds > clip.length * 0.9 {
                try picture.insertTimeRange(available, of: smoothVideo, at: stamp(at))
                if abs(available.duration.seconds - output) > 0.000001 {
                    picture.scaleTimeRange(CMTimeRange(start: stamp(at), duration: available.duration), toDuration: stamp(output))
                }
            } else {
                try picture.insertTimeRange(range, of: video, at: stamp(at))
                if abs(output - length) > 0.000001 {
                    picture.scaleTimeRange(CMTimeRange(start: stamp(at), duration: stamp(length)), toDuration: stamp(output))
                }
            }
            guard withSound, let sound, let audio else { return }
            let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
            guard available.duration.seconds > 0.000001 else { return }
            let offset = available.start.seconds - from
            try sound.insertTimeRange(available, of: audio, at: stamp(at + offset * output / length))
            if abs(output - length) > 0.000001 {
                sound.scaleTimeRange(CMTimeRange(start: stamp(at + offset * output / length), duration: available.duration),
                                     toDuration: stamp(available.duration.seconds * output / length))
            }
        }
        for s in segments {
            switch s.kind {
            case .play:
                try place(s.from, s.to - s.from, at: s.outputStart, output: s.outputLength, withSound: !s.isReplay)
            case .hold:
                // Start just inside the chosen frame so rounding never lands on its predecessor.
                let frame = frames.nearest(s.from), length = frames.frameDuration(at: frame)
                let epsilon = min(0.000001, length / 100)
                try place(frame + epsilon, length - epsilon, at: s.outputStart, output: s.outputLength, withSound: false)
            case .rewind:
                let step = max(1.0 / 120, frames.frameDuration(at: s.from))
                let count = max(1, Int((s.outputLength / step).rounded()))
                for i in 0..<count {
                    let t = frames.nearest(s.from + (s.to - s.from) * Double(i) / Double(max(1, count - 1)))
                    let length = frames.frameDuration(at: t), epsilon = min(0.000001, length / 100)
                    try place(t + epsilon, length - epsilon, at: s.outputStart + Double(i) * s.outputLength / Double(count),
                              output: s.outputLength / Double(count), withSound: false)
                }
            }
        }
        return composition
    }
}
