import CoreVideo
import Foundation

/// One replaceable, matched image/observation for presentation. Counting owns
/// its existing queue; the screen never queues work or retains a video history.
nonisolated final class LiveEffectFrames: @unchecked Sendable {
    struct Frame {
        let pixels: CVPixelBuffer
        let time: Double
        let due: Double
        let sequence: Int
        let sample: BallStyleSample?
        let trail: [BallStyleSample]
    }
    private let lock = NSLock()
    private var enabled = false
    private var latest: Frame?
    private var trail: [BallStyleSample] = []
    private var sequence = 0

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        if !value { latest = nil; trail.removeAll(keepingCapacity: false) }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        latest = nil; trail.removeAll(keepingCapacity: false)
    }

    func publish(pixels: CVPixelBuffer, time: Double, due: Double, ball: Detection?) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, time.isFinite, due.isFinite else { return }
        if let latest, time <= latest.time { return }
        var sample = ball.flatMap { BallStyleSample(box: CGRect(x: $0.x - $0.width / 2,
            y: $0.y - $0.height / 2, width: $0.width, height: $0.height), confidence: $0.score) }
        sample?.time = time
        trail.removeAll { time - $0.time > 0.85 }
        if let sample { trail.append(sample) }
        if trail.count > 32 { trail.removeFirst(trail.count - 32) }
        sequence &+= 1
        latest = Frame(pixels: pixels, time: time, due: due, sequence: sequence,
                       sample: sample, trail: trail)
    }

    /// A stalled analysis must reveal the normal camera, not freeze the viewfinder.
    func frame(now: Double = ProcessInfo.processInfo.systemUptime) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, now - latest.due < 0.7 else {
            latest = nil; trail.removeAll(keepingCapacity: true)
            return nil
        }
        return latest
    }
}
