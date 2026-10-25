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
nonisolated struct CounterConfig: Codable, Equatable, Sendable {
    /// Missing in historical traces means their original frame-based behavior.
    var timeAwareTrajectory: Bool? = true
    /// Nil keeps historical foot/floor decisions exactly replayable.
    var cadenceAwareGroundContact: Bool? = true
    /// Nil preserves historical person-box floor estimates in saved traces.
    var stabilizesPlayerGround: Bool? = true
    var medianWindow = 3
    var smoothingWindow = 3
    var velocityThreshold = 0.05
    var maxGapFrames = 8
    /// Eight missing frames at 30 fps span 300 ms between observations. A
    /// stalled camera must not silently turn that into seconds of interpolation.
    var maxGapDurationMs = 300
    var minStateFrames = 2
    /// Maximum required descent in frame heights; nearby observed ball sizes
    /// reduce this for soft keep-ups without relaxing the other contact gates.
    var minFallAmplitude = 0.02
    var minFallBallHeights = 0.10
    var minRiseAmplitude = 0.007
    /// A confirmed rising run can reach the required displacement while slowing
    /// below the velocity threshold. Missing in old traces means legacy behavior.
    var completesRiseWhileSlowing: Bool? = true
    /// An observed descent may resume after a short detector outage at high
    /// FPS. Do not infer a reversal inside the gap. Nil preserves old traces.
    var preservesFallingArcAcrossShortGap: Bool? = true
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

nonisolated struct Region {
    var xMin, yMin, xMax, yMax: Double

    func contains(_ x: Double, _ y: Double, margin: Double) -> Bool {
        x >= xMin - margin && x <= xMax + margin && y >= yMin - margin && y <= yMax + margin
    }
}

nonisolated struct PersonBox: Codable, Equatable, Sendable {
    var x, y, width, height: Double

    var bottom: Double { y + height / 2 }

    /// The fraction of the box, measured up from the bottom, treated as in-play.
    func region(fraction: Double) -> Region {
        let top = y + height / 2 - height * fraction
        return Region(xMin: x - width / 2, yMin: top, xMax: x + width / 2, yMax: y + height / 2)
    }
}

nonisolated enum MotionState { case falling, rising, unknown }

/// Previous rules are retained for exact replay of saved traces.
nonisolated enum GroundContactPolicy: Equatable, Sendable {
    case legacyCenter, observedBoundary, supportedBoundary, plantedFeet, corroboratedFeet
    var revision: String {
        switch self {
        case .legacyCenter: "counter-v5"
        case .observedBoundary: "counter-v6"
        case .supportedBoundary: "counter-v7"
        case .plantedFeet: "counter-v8"
        case .corroboratedFeet: "counter-v9"
        }
    }
}

nonisolated struct TrajectoryPoint {
    var frameIndex: Int
    var timestampMs: Int
    var x, y: Double
    var vy: Double
    var confidence: Double
    var valid: Bool
    var motion: MotionState
    /// Time supported by consecutive real observations in this direction.
    /// Nil keeps the established dense-frame confirmation rule.
    var motionEvidenceMs: Double? = nil
}

nonisolated struct Touch: Codable, Equatable, Sendable {
    var index: Int
    var frameIndex: Int
    var timestampMs: Int
    var x, y: Double
    var fallAmplitude: Double
    var riseAmplitude: Double
    var impulse: Double
}

nonisolated enum RejectionReason: String, Codable, Sendable {
    case amplitudeTooSmall, insufficientImpulse, groundBounce, cooldown
    case unsupportedByDetection, noPersonRegion, outsidePersonRegion, trackLost
    case handContact, disallowedBodyContact, heldBall, unresolvedLowContact
}

/// One accepted or rejected trajectory proposal. Missing fields indicate a
/// continuity break rather than a fully evaluated reversal.
nonisolated struct CounterDecision: Codable, Equatable, Sendable {
    let frameIndex, timestampMs: Int
    let rejection: RejectionReason?
    var handRejected: Bool? = nil
    var bodyContactAllowed: Bool? = nil
    var footConfirmed: Bool? = nil
    var footEvidence: FootContactEvidence? = nil
    var fall: Double? = nil
    var requiredFall: Double? = nil
    var rise: Double? = nil
    var impulse: Double? = nil
    var ground: Double? = nil
    /// Corroborated, unsmoothed lower ball edge in trajectory coordinates.
    var observedBallBottom: Double? = nil
    var plantedFeetConfirmed: Bool? = nil
    var groundEvidence: GroundContactEvidence? = nil
    var handlingEvidence: BallHandlingEvidence? = nil
    var handlingChecked: Bool? = nil
}

// MARK: - State machine

/// One trajectory point in, at most one touch out.
///
/// The counter was always causal - a single forward pass that reads the current
/// point and the arc it is following, never a later frame. What needed bounding
/// for live use is the *trajectory* feeding it, handled in `StreamingCounter`.
nonisolated final class TouchStateMachine {
    private let config: CounterConfig
    private let groundPolicy: GroundContactPolicy
    private(set) var touches: [Touch] = []
    private(set) var rejected: [(frame: Int, reason: RejectionReason)] = []

    private var armed = false
    private var apex: TrajectoryPoint?
    var pendingContactFrameIndex: Int? { armed ? apex?.frameIndex : nil }
    private var arcTopY: Double?
    private var peakFall = 0.0
    private var peakRise = 0.0
    private var fallingRun = 0
    private var risingRun = 0
    private var gapRun = 0
    private var lastTouchMs: Int?
    private var lastValidPoint: TrajectoryPoint?

    /// Per-frame body geometry, filled by the caller as frames arrive.
    var personBoxes: [Int: PersonBox] = [:]
    /// Presence without a value means the selected player has no reliable floor.
    var playerGroundFrames: Set<Int> = []
    var playerGrounds: [Int: Double] = [:]
    /// Real detections only, in the same frame-height units as the trajectory.
    /// The streaming caller bounds this history and clears it at discontinuities.
    var ballHeights: [Int: Double] = [:]
    var observedBalls: [Int: BallObservation] = [:]
    /// Bottom of the visible image, in the same compensated coordinates.
    var imageBottoms: [Int: Double] = [:]
    var detectedFrames: Set<Int> = []
    var rejectsHandContact: ((Int) -> Bool)?
    var allowsBodyContact: ((Int) -> Bool)?
    var footContactEvidence: ((Int) -> FootContactEvidence?)?
    var groundContactEvidence: ((Int) -> GroundContactEvidence?)?
    var handlingEvidence: ((Int) -> BallHandlingEvidence?)?
    var onDecision: ((CounterDecision) -> Void)?

    var count: Int { touches.count }

    init(config: CounterConfig, groundPolicy: GroundContactPolicy = .corroboratedFeet) {
        self.config = config
        self.groundPolicy = groundPolicy
    }

    private var fallEvidenceMs = 0.0
    private var riseEvidenceMs = 0.0

    private func resetArc(restartTopY: Double? = nil) {
        armed = false
        apex = nil
        peakFall = 0
        peakRise = 0
        fallingRun = 0
        risingRun = 0
        fallEvidenceMs = 0
        riseEvidenceMs = 0
        arcTopY = restartTopY
    }

    /// Preserve confirmed touches, but never finish an arc across a capture
    /// discontinuity or a period when camera motion made observations unusable.
    func discardPendingArc() {
        if armed, let a = apex { rejectLost(a) }
        resetArc()
        gapRun = 0
    }

    private func rejectLost(_ point: TrajectoryPoint) {
        rejected.append((point.frameIndex, .trackLost))
        onDecision?(CounterDecision(frameIndex: point.frameIndex, timestampMs: point.timestampMs,
                                    rejection: .trackLost))
    }

    func push(_ point: TrajectoryPoint) -> Touch? {
        guard point.valid else {
            gapRun += 1
            let mayResumeDescent = config.preservesFallingArcAcrossShortGap == true
                && armed && lastValidPoint?.motion == .falling
                && point.timestampMs-(lastValidPoint?.timestampMs ?? point.timestampMs) <= config.maxGapDurationMs
            if gapRun > config.maxGapFrames && !mayResumeDescent {
                // A long disappearance invalidates the arc: we cannot claim a
                // reversal we never saw completed.
                if armed, let a = apex {
                    rejectLost(a)
                }
                resetArc()
            }
            return nil
        }
        if config.preservesFallingArcAcrossShortGap == true, gapRun > config.maxGapFrames,
           let previous = lastValidPoint {
            // Keep only a continuing observed descent. A ball returning above
            // its old position could have bounced off-screen and starts anew.
            if point.timestampMs-previous.timestampMs > config.maxGapDurationMs
                || previous.motion != .falling || point.motion != .falling || point.y < previous.y {
                discardPendingArc()
            }
        }
        gapRun = 0
        lastValidPoint = point

        if !armed {
            arcTopY = arcTopY.map { min($0, point.y) } ?? point.y
        }

        switch point.motion {
        case .falling:
            fallingRun += 1
            risingRun = 0
            fallEvidenceMs += point.motionEvidenceMs ?? TimedTrajectory.referenceIntervalMs
            riseEvidenceMs = 0
            peakFall = max(peakFall, point.vy)
            if confirmedDirection(at: point, frames: fallingRun, milliseconds: fallEvidenceMs), !armed {
                armed = true
            }
            if armed, apex == nil || point.y > apex!.y {
                // A new low point restarts the outgoing half of the measurement.
                apex = point
                peakRise = 0
            }

        case .rising:
            risingRun += 1
            fallingRun = 0
            riseEvidenceMs += point.motionEvidenceMs ?? TimedTrajectory.referenceIntervalMs
            fallEvidenceMs = 0
            peakRise = max(peakRise, -point.vy)
            return confirmRise(at: point)

        case .unknown:
            // Near the apex the sign of a noisy velocity is meaningless.
            if armed, apex == nil || point.y > apex!.y { apex = point }
            // Keep the required rising run and displacement. A neutral frame
            // does not establish a rise, but can finish one already observed.
            if config.completesRiseWhileSlowing == true, point.vy <= 0 {
                return confirmRise(at: point)
            }
        }
        return nil
    }

    private func confirmRise(at point: TrajectoryPoint) -> Touch? {
        guard armed, let a = apex,
              confirmedDirection(at: point, frames: risingRun, milliseconds: riseEvidenceMs),
              a.y - point.y >= config.minRiseAmplitude else { return nil }
        let touch = evaluate(apex: a, confirmation: point,
                             arcTopY: arcTopY ?? a.y, impulse: peakFall + peakRise)
        resetArc(restartTopY: point.y)
        if let touch {
            touches.append(touch)
            lastTouchMs = touch.timestampMs
        }
        return touch
    }

    private func confirmedDirection(at point: TrajectoryPoint, frames: Int, milliseconds: Double) -> Bool {
        guard point.motionEvidenceMs != nil else { return frames >= config.minStateFrames }
        // Preserve the evidence duration of two 30 FPS direction samples. The
        // tolerance only covers integer-millisecond timestamp rounding.
        return milliseconds >= Double(config.minStateFrames) * TimedTrajectory.referenceIntervalMs - 2
    }

    private func evaluate(apex: TrajectoryPoint, confirmation: TrajectoryPoint,
                          arcTopY: Double, impulse: Double) -> Touch? {
        let fallAmplitude = apex.y - arcTopY
        let riseAmplitude = apex.y - confirmation.y
        let requiredFall = fallThreshold(at: apex.frameIndex)
        let ground = effectiveGround(apex.frameIndex)
        let observedBottom = groundPolicy != .legacyCenter ? observedBallBottom(around: apex) : nil
        let supportedBoundary = groundPolicy == .supportedBoundary || groundPolicy == .plantedFeet || groundPolicy == .corroboratedFeet
        let boundaryTolerance = supportedBoundary
            // A screen-sized margin grows too large for distant low kicks.
            ? min(config.groundTolerance, (ballHeights[apex.frameIndex] ?? 0) * 0.1)
            : config.groundTolerance
        var handRejected: Bool?
        var bodyContactAllowed: Bool?
        var footConfirmed: Bool?
        var footEvidence: FootContactEvidence?
        var groundEvidence: GroundContactEvidence?
        var handling: BallHandlingEvidence?
        var handlingChecked: Bool?
        var plantedFeetConfirmed: Bool?
        let sparseGround = config.cadenceAwareGroundContact == true && apex.motionEvidenceMs != nil
        func confirmsFoot(_ evidence: FootContactEvidence) -> Bool {
            evidence.contact.timestampMs == apex.timestampMs &&
                (FootContactRules.confirms(before: evidence.before, contact: evidence.contact,
                    after: evidence.after, requireBalancedMotion: groundPolicy != .legacyCenter)
                    || (sparseGround && evidence.confirmsExtendedMotion))
        }
        func record(_ reason: RejectionReason?) {
            onDecision?(CounterDecision(frameIndex: apex.frameIndex, timestampMs: apex.timestampMs,
                rejection: reason, handRejected: handRejected, bodyContactAllowed: bodyContactAllowed,
                footConfirmed: footConfirmed, footEvidence: footEvidence, fall: fallAmplitude,
                requiredFall: requiredFall, rise: riseAmplitude, impulse: impulse, ground: ground,
                observedBallBottom: observedBottom, plantedFeetConfirmed: plantedFeetConfirmed,
                groundEvidence: groundEvidence, handlingEvidence: handling, handlingChecked: handlingChecked))
        }
        func reject(_ reason: RejectionReason) -> Touch? {
            rejected.append((apex.frameIndex, reason))
            record(reason)
            return nil
        }

        // A fixed fraction of the image rejected clear low keep-ups (25.6 px
        // at 1280 px). Scale to the observed ball, retaining the rise noise floor
        // and the existing impulse, support, ground and contact checks below.
        if fallAmplitude < requiredFall { return reject(.amplitudeTooSmall) }
        if impulse < config.minTouchImpulse { return reject(.insufficientImpulse) }

        if let ground,
           apex.y >= ground - config.groundTolerance
            || (observedBottom.map { $0 >= ground - boundaryTolerance } ?? false) {
            let region = nearestRegion(apex.frameIndex)
            let eligible = hasDetectionSupport(apex.frameIndex)
                && region?.contains(apex.x, apex.y, margin: config.roiMargin) == true
                && (lastTouchMs.map { apex.timestampMs - $0 >= config.touchCooldownMs } ?? true)
            if eligible, let provider = footContactEvidence {
                footEvidence = provider(apex.frameIndex)
                footConfirmed = footEvidence.map(confirmsFoot) ?? false
            }
            if footConfirmed != true {
                // A person-box bottom is only a rough floor proxy. In a view
                // from above, a toe tap can project below it. Preserve the old
                // centre gate, but require additional evidence for the NEW
                // lower-edge gate: the impact leaves the image, or both feet
                // are confidently stationary while the ball reverses.
                let originalGate = apex.y >= ground - config.groundTolerance
                let clipped = observedBottom.map { bottom in
                    guard let edge = imageBottoms[apex.frameIndex],
                          let height = ballHeights[apex.frameIndex] else { return false }
                    return bottom >= edge - height*0.05
                } ?? false
                let stationary = footEvidence.map {
                    $0.contact.timestampMs == apex.timestampMs && FootContactRules.stationaryFeet($0)
                } ?? false
                if !supportedBoundary || originalGate || clipped || stationary {
                    return reject(.groundBounce)
                }
            }
        }

        if let last = lastTouchMs, apex.timestampMs - last < config.touchCooldownMs {
            return reject(.cooldown)
        }

        if !hasDetectionSupport(apex.frameIndex) { return reject(.unsupportedByDetection) }

        guard let region = nearestRegion(apex.frameIndex) else { return reject(.noPersonRegion) }
        if !region.contains(apex.x, apex.y, margin: config.roiMargin) {
            return reject(.outsidePersonRegion)
        }

        // Check the whole lower-body area, not just a person-box floor line.
        // Perspective and trajectory smoothing can put a real floor impact
        // above that line. This gate requires positive, sustained pose evidence.
        if (groundPolicy == .plantedFeet || groundPolicy == .corroboratedFeet), let person = nearestPerson(apex.frameIndex),
           apex.y + (ballHeights[apex.frameIndex] ?? 0)/2 >= person.bottom-person.height*0.35,
           let provider = groundContactEvidence {
            groundEvidence = provider(apex.frameIndex)
            plantedFeetConfirmed = groundEvidence.map {
                $0.contactMs == apex.timestampMs && $0.confirmsGroundContact(
                    corroboratingWeakAnkles: groundPolicy == .corroboratedFeet,
                    cadenceAware: sparseGround)
            } ?? false
            if plantedFeetConfirmed == true || groundEvidence?.needsPositiveFootContact == true {
                // A resolved kick can still rescue the contact. Reuse a prior
                // check when the body-box ground gate already requested it.
                if footConfirmed == nil, let provider = footContactEvidence {
                    footEvidence = provider(apex.frameIndex)
                    footConfirmed = footEvidence.map(confirmsFoot) ?? false
                }
                if footConfirmed != true {
                    return reject(plantedFeetConfirmed == true ? .groundBounce : .unresolvedLowContact)
                }
            }
        }

        bodyContactAllowed = allowsBodyContact?(apex.frameIndex)
        if bodyContactAllowed == false { return reject(.disallowedBodyContact) }
        handRejected = rejectsHandContact?(apex.frameIndex)
        if handRejected == true { return reject(.handContact) }
        if let provider = handlingEvidence {
            handlingChecked = true
            handling = provider(apex.frameIndex)
            if handling?.contactMs == apex.timestampMs, handling?.state == .held { return reject(.heldBall) }
        }
        record(nil)

        return Touch(index: touches.count, frameIndex: apex.frameIndex,
                     timestampMs: apex.timestampMs, x: apex.x, y: apex.y,
                     fallAmplitude: fallAmplitude, riseAmplitude: riseAmplitude,
                     impulse: impulse)
    }

    /// Reject ground reversals using nearby body bottoms, not a single box
    /// that can briefly clip the lower legs at contact. Uses already buffered
    /// observations (no new lookahead); sparse evidence keeps the old fallback.
    /// This still assumes the player's feet are near the ground and in frame.
    private func effectiveGround(_ frame: Int) -> Double? {
        if config.stabilizesPlayerGround == true, playerGroundFrames.contains(frame) {
            guard let ground = playerGrounds[frame] else { return nil }
            let nearby = (-config.supportWindowFrames...config.supportWindowFrames)
                .compactMap { playerGrounds[frame+$0] }.sorted()
            return nearby.count >= 3 ? nearby[nearby.count/2] : ground
        }
        let bottoms = (-config.supportWindowFrames...config.supportWindowFrames)
            .compactMap { personBoxes[frame + $0]?.bottom }.filter(\.isFinite).sorted()
        guard bottoms.count >= 3 else { return nearestPerson(frame)?.bottom }
        return bottoms[bottoms.count / 2]
    }

    private func observedBallBottom(around apex: TrajectoryPoint) -> Double? {
        let heights = (-config.supportWindowFrames...config.supportWindowFrames)
            .compactMap { ballHeights[apex.frameIndex+$0] }
            .filter { $0.isFinite && $0 > 0 && $0 < 1 }.sorted()
        let typicalHeight = heights.count >= 3 ? heights[heights.count/2] : nil
        let bottoms = (-2...2).compactMap { offset -> (bottom: Double, height: Double)? in
            guard let ball = observedBalls[apex.frameIndex+offset],
                  abs(ball.timestampMs-apex.timestampMs) <= 100,
                  ball.y.isFinite, ball.height.isFinite, ball.confidence.isFinite,
                  ball.confidence >= 0.5, ball.height > 0, ball.height < 1 else { return nil }
            // One oversized box must not turn a good kick into a floor event.
            let height = min(ball.height, typicalHeight.map { 1.35*$0 } ?? ball.height)
            return (ball.y+height/2, height)
        }.sorted { $0.bottom > $1.bottom }
        guard bottoms.count >= 2 else { return nil }
        // A fast impact may reach the floor in only one exposure. Keep that
        // boundary when a second observed edge corroborates it within a ball
        // radius. Otherwise ignore the isolated low outlier.
        let first = bottoms[0], second = bottoms[1]
        return first.bottom-second.bottom <= min(first.height, second.height)/2
            ? first.bottom : second.bottom
    }

    private func fallThreshold(at frame: Int) -> Double {
        let window = config.supportWindowFrames
        let sizes = (-window...window).compactMap { ballHeights[frame + $0] }.sorted()
        // Sparse or missing size evidence must not make a marginal arc easier.
        guard sizes.count >= 3 else { return config.minFallAmplitude }
        let diameter = sizes[sizes.count / 2]
        return min(config.minFallAmplitude,
                   max(config.minRiseAmplitude, diameter * config.minFallBallHeights))
    }

    private func hasDetectionSupport(_ frame: Int) -> Bool {
        guard !detectedFrames.isEmpty else { return false }
        // An unseen reversal bridged between radically different apparent sizes
        // is not reliable contact evidence (e.g. initial ball acquisition). Real
        // observed contacts and consistent short occlusions retain their support.
        if !detectedFrames.contains(frame),
           let before = ballHeights.keys.filter({ $0 < frame && frame - $0 <= config.maxGapFrames + 1 }).max(),
           let after = ballHeights.keys.filter({ $0 > frame && $0 - frame <= config.maxGapFrames + 1 }).min(),
           let a = ballHeights[before], let b = ballHeights[after], max(a, b) > 2 * min(a, b) {
            return false
        }
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
