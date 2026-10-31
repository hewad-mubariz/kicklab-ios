import Foundation

/// Select real observations by elapsed time, independently of the source FPS.
/// The dense neighbors remain available for the original hand/ground checks.
nonisolated enum ContactFrameWindow {
    struct Stamp: Equatable {
        let index: Int
        let timestampMs: Int
    }

    // Dense recent views plus a bounded 400 ms history, legacy contact neighbors,
    // and time-sampled ground/leg evidence. No full-resolution capture buffers.
    static let maximumBufferedFrames = 60

    /// Experimental shared history plan. Keep every impact/release exposure;
    /// only the earlier approach is sparse. Indices always identify the original
    /// complete ball/image/pose observation, never a pose borrowed across frames.
    /// Apply to the already eligible views, without widening any consumer window.
    static func sharedHistoryIndices(_ frames: [Stamp], contactMs: Int) -> Set<Int> {
        var selected = Set(frames.filter { $0.timestampMs >= contactMs - 101 }.map(\.index))
        for offset in [-300, -200] {
            if let nearest = frames.filter({
                $0.timestampMs < contactMs - 101 && abs($0.timestampMs-contactMs-offset) <= 34
            }).min(by: {
                let a = abs($0.timestampMs-contactMs-offset), b = abs($1.timestampMs-contactMs-offset)
                return a == b ? $0.timestampMs < $1.timestampMs : a < b
            }) { selected.insert(nearest.index) }
        }
        return selected
    }

    /// The floor check needs at least 200 ms of approach. At 60/120 fps,
    /// nine preceding frame indices cannot supply that evidence.
    static func groundIndices(_ frames: [Stamp], around contact: Stamp) -> Set<Int> {
        var selected: Set<Int> = [contact.index]
        for offset in [-300, -267, -233, -200, -167, -133, -100, -67, -33, 33, 67, 100] {
            let candidates = frames.filter {
                !selected.contains($0.index)
                    && (-350...150).contains($0.timestampMs-contact.timestampMs)
                    && abs($0.timestampMs-contact.timestampMs-offset) <= 17
            }
            if let nearest = candidates.min(by: {
                let a = abs($0.timestampMs-contact.timestampMs-offset)
                let b = abs($1.timestampMs-contact.timestampMs-offset)
                return a == b ? $0.timestampMs < $1.timestampMs : a < b
            }) { selected.insert(nearest.index) }
        }
        return selected
    }

    static func motionIndices(_ frames: [Stamp], around contact: Stamp) -> Set<Int> {
        let nearby = frames.filter { (-100...150).contains($0.timestampMs-contact.timestampMs) }
        var selected: Set<Int> = [contact.index]
        for offset in [-100, -67, -33, 33, 67, 100] {
            let target = contact.timestampMs + offset
            let candidates = nearby.filter {
                !selected.contains($0.index) && abs($0.timestampMs-target) <= 17
                    && (offset < 0 ? $0.timestampMs < contact.timestampMs : $0.timestampMs > contact.timestampMs)
            }
            if let closest = candidates.min(by: {
                let a = abs($0.timestampMs-target), b = abs($1.timestampMs-target)
                return a == b ? $0.timestampMs < $1.timestampMs : a < b
            }) { selected.insert(closest.index) }
        }
        return selected
    }

    /// Sparse capture can place the smoothed candidate one exposure before
    /// impact. Preserve a real approach and release around that impact, using
    /// at most nine small images that already exist when the counter decides.
    /// One millisecond of rounding keeps 100.02 ms capture intervals usable.
    static func reboundIndices(_ frames: [Stamp], around contact: Stamp) -> Set<Int> {
        var selected: Set<Int> = [contact.index]
        for offset in [-200, -150, -100, -50, 50, 100, 150, 200] {
            let candidates = frames.filter {
                !selected.contains($0.index)
                    && (-201...201).contains($0.timestampMs-contact.timestampMs)
                    && abs($0.timestampMs-contact.timestampMs-offset) <= 25
                    && (offset < 0 ? $0.timestampMs < contact.timestampMs : $0.timestampMs > contact.timestampMs)
            }
            if let nearest = candidates.min(by: {
                let a = abs($0.timestampMs-contact.timestampMs-offset), b = abs($1.timestampMs-contact.timestampMs-offset)
                return a == b ? $0.timestampMs < $1.timestampMs : a < b
            }) { selected.insert(nearest.index) }
        }
        return selected
    }

    /// A pixel foot track can start earlier than the pose samples used by the
    /// existing contact rules. Seven samples at roughly 50 ms spacing keep the
    /// flow bounded while giving the tracker a chance to find a clear pre-kick
    /// ankle when the nearer pose observations are occluded.
    static func trackedFootIndices(_ frames: [Stamp], around contact: Stamp) -> Set<Int> {
        // Allow one frame of timestamp rounding at the +100 ms target (101 ms
        // is common on 30 fps footage).
        let nearby = frames.filter { (-200...120).contains($0.timestampMs-contact.timestampMs) }
        var selected: Set<Int> = [contact.index]
        for offset in [-200, -150, -100, -50, 50, 100] {
            let target = contact.timestampMs + offset
            let candidates = nearby.filter {
                !selected.contains($0.index) && abs($0.timestampMs-target) <= 25
                    && (offset < 0 ? $0.timestampMs < contact.timestampMs : $0.timestampMs > contact.timestampMs)
            }
            if let closest = candidates.min(by: {
                let a = abs($0.timestampMs-target), b = abs($1.timestampMs-target)
                return a == b ? $0.timestampMs < $1.timestampMs : a < b
            }) { selected.insert(closest.index) }
        }
        return selected
    }

    static func retainedIndices(_ frames: [Stamp], latest: Stamp, pendingIndex: Int?, pendingTimestampMs: Int? = nil) -> Set<Int> {
        var retained = Set(frames.filter {
            (0...15).contains(latest.index-$0.index)
                && (0...500).contains(latest.timestampMs-$0.timestampMs)
        }.map(\.index))
        // At high FPS the dense cache covers too little time even before a
        // candidate is known. Keep one real observation per 33 ms history bin.
        var bins: Set<Int> = []
        for frame in frames.sorted(by: { $0.timestampMs < $1.timestampMs })
            where (0...400).contains(latest.timestampMs-frame.timestampMs) {
            if bins.insert(Int(floor(Double(frame.timestampMs)/33))).inserted {
                retained.insert(frame.index)
            }
        }
        if let pendingIndex {
            retained.formUnion(frames.filter { (pendingIndex-9...pendingIndex+3).contains($0.index) }.map(\.index))
            if let contact = frames.first(where: { $0.index == pendingIndex })
                ?? pendingTimestampMs.map({ Stamp(index: pendingIndex, timestampMs: $0) }) {
                retained.formUnion(motionIndices(frames, around: contact))
                retained.formUnion(reboundIndices(frames, around: contact))
                retained.formUnion(trackedFootIndices(frames, around: contact))
                retained.formUnion(groundIndices(frames, around: contact))
            }
        }
        return retained
    }
}
