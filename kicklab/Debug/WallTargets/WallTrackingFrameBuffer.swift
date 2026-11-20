#if DEBUG
import Foundation

/// One analysis owner, a bounded chronological backlog, and no camera wait.
/// The last frame of each batch runs RF; preceding frames run pixel tracking.
/// When overloaded, old frames are dropped rather than accumulating latency.
nonisolated struct WallTrackingFrameBuffer<Frame> {
    static var capacity: Int { 6 }
    private(set) var isRunning = false
    private var pending: [(t: Double, frame: Frame)] = []
    private var lastTime: Double?
    private(set) var buffered = false
    private(set) var dropped = 0

    mutating func setBuffered(_ enabled: Bool) {
        guard buffered != enabled else { return }
        buffered = enabled; pending = []; lastTime = nil
    }
    mutating func offer(_ frame: Frame, at time: Double) -> Frame? {
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else { return nil }
        lastTime = time
        guard isRunning else { isRunning = true; return frame }
        pending.append((time, frame))
        let capacity = buffered ? Self.capacity : 1
        while pending.count > capacity || (pending.first.map { time - $0.t > 0.15 } ?? false) {
            pending.removeFirst(); dropped += 1
        }
        return nil
    }
    mutating func finish() -> [Frame] {
        let result = pending.map(\.frame)
        pending.removeAll(keepingCapacity: true)
        isRunning = !result.isEmpty
        return result
    }
    mutating func cancelPending() { pending = []; lastTime = nil }
}
#endif
