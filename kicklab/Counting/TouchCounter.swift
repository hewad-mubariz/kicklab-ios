//
//  TouchCounter.swift
//  kicklab
//
//  Derived from the Python lab's touch counter (kicklab-lab). Native camera
//  continuity and optional hand verification have their own replay regressions;
//  the offline lab and live configuration are not assumed to be identical.
//
//  Coordinates are normalised 0-1, with y growing downwards. That matters more
//  than it looks: every threshold below is a fraction of the frame, so feeding
//  this pixels would not throw - it would just count wrongly, in a way that
//  looks like a model problem.
//

import Foundation

// MARK: - Configuration

/// Thresholds, defaulted to the lab's live configuration.
///
/// Trajectory thresholds preserve soft legal touches. Hand/arm exclusion uses
/// contact evidence rather than raising the impulse threshold for every touch.
struct CounterConfig {
    var medianWindow = 3
    var smoothingWindow = 3
    var velocityThreshold = 0.05
    var maxGapFrames = 8
    /// Eight missing frames at 30 fps span 300 ms between observations. A
    /// stalled camera must not silently turn that into seconds of interpolation.
    var maxGapDurationMs = 300
    var minStateFrames = 2
    var minFallAmplitude = 0.02
    var minRiseAmplitude = 0.007
    /// Keep soft touches; a separate hand verifier rejects observed handling.
    var minTouchImpulse = 0.2
    var touchCooldownMs = 180
    var groundTolerance = 0.03
    var roiMargin = 0.08
    var personSearchFrames = 12
    /// Head, chest and legs all count. A body box alone cannot identify hands.
    var lowerBodyFraction = 1.0
    var supportWindowFrames = 4

    /// Frames of lookahead needed before a frame can be judged.
    ///
    /// Derived, not chosen: the median filter, the moving average and the
    /// central-difference velocity each read one frame ahead. Measured across
    /// eight clips, this exactly reproduces the offline count; one frame less
    /// costs touches.
    var lookahead: Int { 3 }
}

// MARK: - Geometry

struct Region {
    var xMin, yMin, xMax, yMax: Double

    func contains(_ x: Double, _ y: Double, margin: Double) -> Bool {
        x >= xMin - margin && x <= xMax + margin && y >= yMin - margin && y <= yMax + margin
    }
}

struct PersonBox {
    var x, y, width, height: Double

    var bottom: Double { y + height / 2 }

    /// The fraction of the box, measured up from the bottom, treated as in-play.
    func region(fraction: Double) -> Region {
        let top = y + height / 2 - height * fraction
        return Region(xMin: x - width / 2, yMin: top, xMax: x + width / 2, yMax: y + height / 2)
    }
}

enum MotionState { case falling, rising, unknown }

struct TrajectoryPoint {
    var frameIndex: Int
    var timestampMs: Int
    var x, y: Double
    var vy: Double
    var confidence: Double
    var valid: Bool
    var motion: MotionState
}

struct Touch {
    var index: Int
    var frameIndex: Int
    var timestampMs: Int
    var x, y: Double
    var fallAmplitude: Double
    var riseAmplitude: Double
    var impulse: Double
}

enum RejectionReason: String {
    case amplitudeTooSmall, insufficientImpulse, groundBounce, cooldown
    case unsupportedByDetection, noPersonRegion, outsidePersonRegion, trackLost
    case handContact
}

// MARK: - State machine

/// One trajectory point in, at most one touch out.
///
/// The counter was always causal - a single forward pass that reads the current
/// point and the arc it is following, never a later frame. What needed bounding
/// for live use is the *trajectory* feeding it, handled in `StreamingCounter`.
final class TouchStateMachine {
    private let config: CounterConfig
    private(set) var touches: [Touch] = []
    private(set) var rejected: [(frame: Int, reason: RejectionReason)] = []

    private var armed = false
    private var apex: TrajectoryPoint?
    private var arcTopY: Double?
    private var peakFall = 0.0
    private var peakRise = 0.0
    private var fallingRun = 0
    private var risingRun = 0
    private var gapRun = 0
    private var lastTouchMs: Int?

    /// Per-frame body geometry, filled by the caller as frames arrive.
    var personBoxes: [Int: PersonBox] = [:]
    var detectedFrames: Set<Int> = []
    var rejectsHandContact: ((Int) -> Bool)?

    var count: Int { touches.count }

    init(config: CounterConfig) { self.config = config }

    private func resetArc(restartTopY: Double? = nil) {
        armed = false
        apex = nil
        peakFall = 0
        peakRise = 0
        fallingRun = 0
        risingRun = 0
        arcTopY = restartTopY
    }

    /// Preserve confirmed touches, but never finish an arc across a capture
    /// discontinuity or a period when camera motion made observations unusable.
    func discardPendingArc() {
        if armed, let a = apex { rejected.append((a.frameIndex, .trackLost)) }
        resetArc()
        gapRun = 0
    }

    func push(_ point: TrajectoryPoint) -> Touch? {
        guard point.valid else {
            gapRun += 1
            if gapRun > config.maxGapFrames {
                // A long disappearance invalidates the arc: we cannot claim a
                // reversal we never saw completed.
                if armed, let a = apex {
                    rejected.append((a.frameIndex, .trackLost))
                }
                resetArc()
            }
            return nil
        }
        gapRun = 0

        if !armed {
            arcTopY = arcTopY.map { min($0, point.y) } ?? point.y
        }

        switch point.motion {
        case .falling:
            fallingRun += 1
            risingRun = 0
            peakFall = max(peakFall, point.vy)
            if fallingRun >= config.minStateFrames && !armed { armed = true }
            if armed, apex == nil || point.y > apex!.y {
                // A new low point restarts the outgoing half of the measurement.
                apex = point
                peakRise = 0
            }

        case .rising:
            risingRun += 1
            fallingRun = 0
            peakRise = max(peakRise, -point.vy)
            // Confirm only once the ball has climbed back out of the reversal;
            // a fixed frame offset would reject slow rises.
            if armed, let a = apex,
               risingRun >= config.minStateFrames,
               a.y - point.y >= config.minRiseAmplitude {
                let touch = evaluate(apex: a, confirmation: point,
                                     arcTopY: arcTopY ?? a.y,
                                     impulse: peakFall + peakRise)
                resetArc(restartTopY: point.y)
                if let t = touch {
                    touches.append(t)
                    lastTouchMs = t.timestampMs
                    return t
                }
                return nil
            }

        case .unknown:
            // Near the apex the sign of a noisy velocity is meaningless.
            if armed, apex == nil || point.y > apex!.y { apex = point }
        }
        return nil
    }

    private func evaluate(apex: TrajectoryPoint, confirmation: TrajectoryPoint,
                          arcTopY: Double, impulse: Double) -> Touch? {
        func reject(_ reason: RejectionReason) -> Touch? {
            rejected.append((apex.frameIndex, reason))
            return nil
        }

        let fallAmplitude = apex.y - arcTopY
        let riseAmplitude = apex.y - confirmation.y

        // Without pose there is nothing to rescue a small fall: amplitude alone
        // cannot tell a soft strike from jitter. The lab's pose path does this
        // better and is parked, not deleted.
        if fallAmplitude < config.minFallAmplitude { return reject(.amplitudeTooSmall) }
        if impulse < config.minTouchImpulse { return reject(.insufficientImpulse) }

        if let ground = effectiveGround(apex.frameIndex),
           apex.y >= ground - config.groundTolerance {
            return reject(.groundBounce)
        }

        if let last = lastTouchMs, apex.timestampMs - last < config.touchCooldownMs {
            return reject(.cooldown)
        }

        if !hasDetectionSupport(apex.frameIndex) { return reject(.unsupportedByDetection) }

        guard let region = nearestRegion(apex.frameIndex) else { return reject(.noPersonRegion) }
        if !region.contains(apex.x, apex.y, margin: config.roiMargin) {
            return reject(.outsidePersonRegion)
        }

        if rejectsHandContact?(apex.frameIndex) == true { return reject(.handContact) }

        return Touch(index: touches.count, frameIndex: apex.frameIndex,
                     timestampMs: apex.timestampMs, x: apex.x, y: apex.y,
                     fallAmplitude: fallAmplitude, riseAmplitude: riseAmplitude,
                     impulse: impulse)
    }

    /// The floor line, taken from the bottom of the person box.
    ///
    /// This assumes the player's feet are on the ground and in frame. When they
    /// are not, ground-bounce rejection misfires - a known weakness carried over
    /// from the lab rather than fixed here.
    private func effectiveGround(_ frame: Int) -> Double? {
        nearestPerson(frame)?.bottom
    }

    private func hasDetectionSupport(_ frame: Int) -> Bool {
        guard !detectedFrames.isEmpty else { return false }
        let w = config.supportWindowFrames
        return (-w...w).contains { detectedFrames.contains(frame + $0) }
    }

    private func nearestPerson(_ frame: Int) -> PersonBox? {
        if let exact = personBoxes[frame] { return exact }
        for offset in 1...max(1, config.personSearchFrames) {
            if let before = personBoxes[frame - offset] { return before }
            if let after = personBoxes[frame + offset] { return after }
        }
        return nil
    }

    private func nearestRegion(_ frame: Int) -> Region? {
        nearestPerson(frame)?.region(fraction: config.lowerBodyFraction)
    }
}
