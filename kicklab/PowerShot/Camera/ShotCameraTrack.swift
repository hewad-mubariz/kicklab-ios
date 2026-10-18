import Foundation

/// One camera move placed on the shot: which move, when (source seconds) and how.
nonisolated struct ShotCameraClip: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var move: ShotCameraMove
    var start: Double
    var end: Double
    var settings: ShotMoveSettings

    init(id: UUID = UUID(), move: ShotCameraMove, start: Double, end: Double, settings: ShotMoveSettings? = nil) {
        self.id = id; self.move = move; self.start = start; self.end = end
        self.settings = settings ?? .defaults(for: move)
    }

    var length: Double { end - start }
    func contains(_ time: Double) -> Bool { time >= start - 0.00001 && time <= end + 0.00001 }
}

/// The camera track: moves back to back, never overlapping, in source time. Every edit is a
/// pure function so the timeline UI, preview and export always agree on what the track is.
nonisolated struct ShotCameraTrack: Equatable, Codable, Sendable {
    static let minimumLength = 0.1
    /// Edits closer than this to a strike, playhead or neighbour edge land on it.
    static let snapDistance = 0.06

    private(set) var clips: [ShotCameraClip] = []
    /// The contact moment when the user set it; otherwise it comes from the ball's flight.
    var strike: Double?

    init(clips: [ShotCameraClip] = [], strike: Double? = nil) {
        self.clips = clips.sorted { $0.start < $1.start }
        self.strike = strike
    }

    var isEmpty: Bool { clips.isEmpty }
    var retimes: Bool { clips.contains { $0.move.retimes } }

    func clip(_ id: UUID?) -> ShotCameraClip? { clips.first { $0.id == id } }
    func clip(at time: Double) -> ShotCameraClip? { clips.first { $0.contains(time) } }
    func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    /// The space a clip may occupy without touching its neighbours.
    func room(for id: UUID, duration: Double) -> ClosedRange<Double> {
        guard let i = index(of: id) else { return 0...duration }
        let lo = i > 0 ? clips[i - 1].end : 0
        let hi = i + 1 < clips.count ? clips[i + 1].start : duration
        return lo...max(lo, hi)
    }

    /// Moves the strike to `time` and carries every block with it, so a punch, freeze or arc stays on
    /// the moment it was placed on. Blocks move together and stop at the ends of the shot.
    mutating func moveStrike(from current: Double, to time: Double, duration: Double) {
        var delta = time - current
        if let first = clips.map(\.start).min(), let last = clips.map(\.end).max() {
            delta = min(max(delta, -first), max(0, duration - last))
        }
        if abs(delta) > 0.000001 {
            clips = clips.map { clip in
                var moved = clip
                moved.start += delta; moved.end += delta
                return moved
            }
        }
        strike = min(duration, max(0, time))
    }

    /// Adds a move. It takes its preferred range; neighbours it overlaps give way (trimmed, or
    /// removed when nothing useful is left of them). Returns the new clip's id.
    @discardableResult
    mutating func insert(_ move: ShotCameraMove, range: ClosedRange<Double>, duration: Double) -> UUID {
        let lo = min(max(0, range.lowerBound), max(0, duration - Self.minimumLength))
        let hi = min(duration, max(lo + Self.minimumLength, range.upperBound))
        let clip = ShotCameraClip(move: move, start: lo, end: hi)
        carve(lo...hi)
        clips.append(clip)
        clips.sort { $0.start < $1.start }
        return clip.id
    }

    /// Where a new block should go without disturbing what is already there: its preferred range
    /// if free; otherwise the free gap it overlaps most (trimmed to fit), or the nearest gap that
    /// holds a useful block. Nil when the track has no room left.
    func fit(_ range: ClosedRange<Double>, duration: Double) -> ClosedRange<Double>? {
        let wanted = range.upperBound - range.lowerBound
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for clip in clips {
            if clip.start - cursor >= Self.minimumLength { gaps.append(cursor...clip.start) }
            cursor = max(cursor, clip.end)
        }
        if duration - cursor >= Self.minimumLength { gaps.append(cursor...duration) }
        guard !gaps.isEmpty else { return nil }
        func overlap(_ g: ClosedRange<Double>) -> Double { max(0, min(g.upperBound, range.upperBound) - max(g.lowerBound, range.lowerBound)) }
        // Most of the preferred range, inside one gap.
        if let best = gaps.max(by: { overlap($0) < overlap($1) }), overlap(best) >= min(wanted * 0.5, 0.3), overlap(best) >= Self.minimumLength {
            return max(best.lowerBound, range.lowerBound)...min(best.upperBound, range.upperBound)
        }
        // Otherwise the nearest gap with room, filled from its start.
        let usable = gaps.filter { $0.upperBound - $0.lowerBound >= min(wanted, 0.3) }
        guard let near = usable.min(by: { abs($0.lowerBound - range.lowerBound) < abs($1.lowerBound - range.lowerBound) }) else { return nil }
        return near.lowerBound...min(near.upperBound, near.lowerBound + wanted)
    }

    /// Swaps the move in a block, keeping its time range. Settings start fresh for the new move.
    mutating func replace(_ id: UUID, with move: ShotCameraMove) {
        guard let i = index(of: id), clips[i].move != move else { return }
        clips[i].move = move
        clips[i].settings = .defaults(for: move)
    }

    mutating func remove(_ id: UUID) { clips.removeAll { $0.id == id } }

    mutating func update(_ id: UUID, _ change: (inout ShotMoveSettings) -> Void) {
        guard let i = index(of: id) else { return }
        change(&clips[i].settings)
    }

    /// Slides a whole block, stopping against neighbours, snapping its edges to `snaps`.
    mutating func move(_ id: UUID, toStart requested: Double, duration: Double, snaps: [Double] = [], within: Double = snapDistance) {
        guard let i = index(of: id) else { return }
        let length = clips[i].length
        let room = self.room(for: id, duration: duration)
        var start = requested
        // Either edge may catch a snap point; the nearer one wins.
        if let s = Self.snap(start, to: snaps, within: within), let e = Self.snap(start + length, to: snaps, within: within) {
            start = abs(s - start) <= abs(e - (start + length)) ? s : e - length
        } else if let s = Self.snap(start, to: snaps, within: within) {
            start = s
        } else if let e = Self.snap(start + length, to: snaps, within: within) {
            start = e - length
        }
        start = min(max(room.lowerBound, start), room.upperBound - length)
        clips[i].start = max(room.lowerBound, start)
        clips[i].end = min(room.upperBound, clips[i].start + length)
    }

    enum Edge: Sendable { case start, end }

    /// Moves one edge of a block, within its neighbours and never shorter than the minimum.
    mutating func trim(_ id: UUID, edge: Edge, to requested: Double, duration: Double, snaps: [Double] = [], within: Double = snapDistance) {
        guard let i = index(of: id) else { return }
        let room = self.room(for: id, duration: duration)
        let t = Self.snap(requested, to: snaps, within: within) ?? requested
        switch edge {
        case .start: clips[i].start = min(max(room.lowerBound, t), clips[i].end - Self.minimumLength)
        case .end: clips[i].end = max(min(room.upperBound, t), clips[i].start + Self.minimumLength)
        }
    }

    /// The nearest snap point within `snapDistance`, if any.
    static func snap(_ time: Double, to points: [Double], within: Double = snapDistance) -> Double? {
        points.filter { abs($0 - time) <= within }.min { abs($0 - time) < abs($1 - time) }
    }

    /// Clears `range` for a new block: overlapped neighbours are trimmed back, or removed.
    private mutating func carve(_ range: ClosedRange<Double>) {
        var kept: [ShotCameraClip] = []
        for var clip in clips {
            if clip.end <= range.lowerBound || clip.start >= range.upperBound { kept.append(clip); continue }
            // Keep whichever side of the new block is longer, if it is still a usable block.
            let before = range.lowerBound - clip.start, after = clip.end - range.upperBound
            if before >= after, before >= Self.minimumLength {
                clip.end = range.lowerBound; kept.append(clip)
            } else if after >= Self.minimumLength {
                clip.start = range.upperBound; kept.append(clip)
            }
        }
        clips = kept
    }
}
