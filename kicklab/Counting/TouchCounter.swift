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
    /// An observed, fully framed ball just beyond the player box may be a side
    /// kick. Positive foot contact can establish region eligibility; nil keeps
    /// historical decisions and their requested evidence exactly replayable.
    var recoversVisibleFootOutsideRegion: Bool? = nil
    /// Permit the verifier to measure a missing candidate image before region
    /// rejection. Acceptance still needs a fully framed observed contact and
    /// positive foot proof, both serialized in the decision evidence.
    var usesRecheckedRegionContact: Bool? = nil
    /// A small but resolved arc may request measured foot proof instead of
    /// relying on a missing-size fallback threshold. The rise noise floor and
    /// all downstream vetoes still apply.
    var recoversSmallVisibleContacts: Bool? = nil
    /// A resolved short arc may request positive foot evidence before smoothing
    /// erases it. This changes eligibility only; all contact vetoes still run.
    /// Nil preserves saved trajectories and their original verification calls.
    var recoversMeasuredSmallArcs: Bool? = nil
    /// A real observed rebound can survive below the smoothed velocity floor.
    /// It may only request positive foot proof; nil preserves historical traces.
    var recoversMeasuredSlowRise: Bool? = nil
    /// Two actual release views may finish a rebound at a tracking boundary.
    /// Nil preserves the historical smoothing and evidence requests.
    var recoversMeasuredTerminalRebound: Bool? = nil
    /// Request positive measured contact evidence for a raw observed turn
    /// bracketing a short hole; never count the interpolated path itself.
    var recoversMeasuredGapRebound: Bool? = nil
    /// Debug experiment: a small raw turn may request foot proof when smoothing
    /// never arms an arc. Nil keeps historical candidate and evidence timing.
    var recoversUnsmoothedFootRebound: Bool? = nil
    /// Two measured release views may jointly confirm a short tracking gap.
    var usesJointGapRelease: Bool? = nil
    /// A completed shallow raw rebound may request measured foot evidence
    /// after descent resumes. Nil preserves all historical proposal timing.
    var probesSettledMeasuredRebound: Bool? = nil
    /// Near ankle height, a ball separated from both feet needs positive foot
    /// evidence when the impact track was interrupted. Nil preserves old traces.
    var requiresDistantLowFootProof: Bool? = nil
    /// A measured adjacent foot contact retains its own exposure timestamp.
    /// Nil preserves the historical region gate and exact saved replays.
    var recoversAlignedFootRegion: Bool? = nil
    var recoversBriefToeLift: Bool? = nil
    var rejectsDescendingFloorRebound: Bool? = nil
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
    private var unliftedFloorRejectedFrame: Int?
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
    private var smallRiseProbeFrame: Int?
    private var gapReboundProbeFrame: Int?
    private var rawReboundProbeFrame: Int?
    private var settledReboundProbeMs: Int?

    private func resetArc(restartTopY: Double? = nil) {
        armed = false
        apex = nil
        peakFall = 0
        peakRise = 0
        fallingRun = 0
        risingRun = 0
        fallEvidenceMs = 0
        riseEvidenceMs = 0
        smallRiseProbeFrame = nil
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
            if gapRun == 0, let touch = confirmMeasuredTerminalRebound(before: point) { return touch }
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
        if let touch = confirmUnsmoothedFootRebound(at: point) { return touch }
        if let touch = confirmMeasuredGapRebound(at: point) { return touch }
        if let touch = confirmSettledMeasuredRebound(at: point) { return touch }

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

    /// When a short hole hides the turn, smoothing may never propose a
    /// candidate. The observed descent and two release views may request the
    /// existing bounded contact-image check. Acceptance ALWAYS needs positive
    /// measured foot/leg evidence; the trajectory alone is insufficient.
    private func confirmMeasuredGapRebound(at point: TrajectoryPoint) -> Touch? {
        guard config.recoversMeasuredGapRebound == true, armed, footContactEvidence != nil,
              allowsBodyContact != nil, rejectsHandContact != nil else { return nil }
        let views = observedBalls.values.filter {
            (0...401).contains(point.timestampMs-$0.timestampMs)
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard views.count >= 4, let release = views.last, release.timestampMs == point.timestampMs else { return nil }
        let firstRelease=views[views.count-2],contact=views[views.count-3],approach=views[views.count-4]
        guard gapReboundProbeFrame != contact.frameIndex,
              (25...100).contains(contact.timestampMs-approach.timestampMs),
              (101...234).contains(firstRelease.timestampMs-contact.timestampMs),
              (25...67).contains(release.timestampMs-firstRelease.timestampMs),
              release.frameIndex == firstRelease.frameIndex+1,
              lastTouchMs.map({ contact.timestampMs-$0 >= config.touchCooldownMs }) ?? true else { return nil }
        let measured=[approach,contact,firstRelease,release]
        guard measured.allSatisfy({ b in
            [b.x,b.y,b.width,b.height,b.confidence].allSatisfy(\.isFinite)
                && b.confidence >= 0.7 && b.width > 0 && b.height > 0
                && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                && b.y-b.height/2 >= 0 && b.y+b.height/2 <= (imageBottoms[b.frameIndex] ?? 1)
        }), measured.map(\.height).max()! <= 1.35*measured.map(\.height).min()!,
            measured.map(\.width).max()! <= 1.35*measured.map(\.width).min()!,
            contact.y-approach.y >= max(0.007,0.35*contact.height),
            contact.y-firstRelease.y >= (config.usesJointGapRelease == true
                ? max(0.0035,0.05*contact.height) : max(0.007,0.12*contact.height)),
            contact.y-release.y >= max(0.007,0.12*contact.height),
            firstRelease.y-release.y >= 0.0035 else { return nil }
        gapReboundProbeFrame=contact.frameIndex
        let fall=(contact.y-approach.y)/Double(contact.timestampMs-approach.timestampMs)*1000
        let rise=(contact.y-release.y)/Double(release.timestampMs-contact.timestampMs)*1000
        let impact=TrajectoryPoint(frameIndex:contact.frameIndex,timestampMs:contact.timestampMs,
            x:contact.x,y:contact.y,vy:fall,confidence:contact.confidence,valid:true,motion:.falling)
        let confirmation=TrajectoryPoint(frameIndex:release.frameIndex,timestampMs:release.timestampMs,
            x:release.x,y:release.y,vy:-rise,confidence:release.confidence,valid:true,motion:.rising)
        guard let touch=evaluate(apex:impact,confirmation:confirmation,arcTopY:approach.y,
            impulse:fall+rise,requiresMeasuredFoot:true) else { return nil }
        resetArc(restartTopY:release.y)
        touches.append(touch);lastTouchMs=touch.timestampMs
        return touch
    }

    /// Wait until the raw rebound has finished before probing a turn erased
    /// by smoothing. This never approves a trajectory by itself: a real foot
    /// proof and every downstream veto are still required. Failed probes leave
    /// the ordinary arc intact, and one physical window cannot retry endlessly.
    private func confirmSettledMeasuredRebound(at point: TrajectoryPoint) -> Touch? {
        guard config.probesSettledMeasuredRebound == true,
              footContactEvidence != nil, allowsBodyContact != nil,
              rejectsHandContact != nil else { return nil }
        let views = observedBalls.values.filter {
            (0...401).contains(point.timestampMs-$0.timestampMs)
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard views.count >= 5, let current = views.last,
              current.timestampMs == point.timestampMs else { return nil }
        let previous = views[views.count-2]
        guard (25...100).contains(current.timestampMs-previous.timestampMs),
              current.y-previous.y >= 0.0035 else { return nil }
        func visible(_ b: BallObservation) -> Bool {
            [b.x,b.y,b.width,b.height,b.confidence].allSatisfy(\.isFinite)
                && b.confidence >= 0.7 && b.width > 0 && b.height > 0
                && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                && b.y-b.height/2 >= 0 && b.y+b.height/2 <= (imageBottoms[b.frameIndex] ?? 1)
        }
        for contact in views where (100...267).contains(current.timestampMs-contact.timestampMs) {
            guard lastTouchMs.map({ contact.timestampMs-$0 >= config.touchCooldownMs }) ?? true,
                  settledReboundProbeMs.map({ contact.timestampMs-$0 >= config.touchCooldownMs }) ?? true,
                  let approach = views.last(where: {
                      (25...134).contains(contact.timestampMs-$0.timestampMs)
                          && contact.y-$0.y >= max(0.007,0.35*contact.height)
                  }) else { continue }
            let outgoing = views.filter {
                $0.timestampMs < current.timestampMs && (25...201).contains($0.timestampMs-contact.timestampMs)
            }
            guard outgoing.count >= 2, let release = outgoing.last,
                  current.timestampMs-release.timestampMs <= 100,
                  outgoing.allSatisfy({ contact.y-$0.y >= max(0.0035,0.05*contact.height) }) else { continue }
            let measured = [approach,contact] + outgoing
            guard measured.allSatisfy(visible),
                  measured.map(\.height).max()! <= 1.35*measured.map(\.height).min()!,
                  measured.map(\.width).max()! <= 1.35*measured.map(\.width).min()! else { continue }
            settledReboundProbeMs = contact.timestampMs
            let fall = (contact.y-approach.y)/Double(contact.timestampMs-approach.timestampMs)*1000
            let rise = (contact.y-release.y)/Double(release.timestampMs-contact.timestampMs)*1000
            let impact = TrajectoryPoint(frameIndex:contact.frameIndex,timestampMs:contact.timestampMs,
                x:contact.x,y:contact.y,vy:fall,confidence:contact.confidence,valid:true,motion:.falling)
            let confirmation = TrajectoryPoint(frameIndex:release.frameIndex,timestampMs:release.timestampMs,
                x:release.x,y:release.y,vy:-rise,confidence:release.confidence,valid:true,motion:.rising)
            guard let touch = evaluate(apex:impact,confirmation:confirmation,
                arcTopY:approach.y,impulse:fall+rise,requiresMeasuredFoot:true) else { return nil }
            resetArc(restartTopY:current.y)
            touches.append(touch); lastTouchMs = touch.timestampMs
            return touch
        }
        return nil
    }

    /// A short visible dip can be erased by the median/velocity filters. Only
    /// an unarmed arc can use this route, so existing normal proposals retain
    /// their timing. Five real images must show descent and two release views;
    /// the same foot, region, ground, body, hand and holding gates still apply.
    private func confirmUnsmoothedFootRebound(at point: TrajectoryPoint) -> Touch? {
        guard config.recoversUnsmoothedFootRebound == true, !armed,
              footContactEvidence != nil, allowsBodyContact != nil,
              rejectsHandContact != nil else { return nil }
        let views = observedBalls.values.filter {
            (0...301).contains(point.timestampMs-$0.timestampMs)
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard views.count >= 5, let release = views.last,
              release.timestampMs == point.timestampMs else { return nil }
        let measured = Array(views.suffix(5))
        let approach = measured[0], incoming = measured[1], contact = measured[2], firstRelease = measured[3]
        guard rawReboundProbeFrame != contact.frameIndex,
              lastTouchMs.map({ contact.timestampMs-$0 >= config.touchCooldownMs }) ?? true,
              (25...67).contains(incoming.timestampMs-approach.timestampMs),
              (25...67).contains(contact.timestampMs-incoming.timestampMs),
              (25...100).contains(firstRelease.timestampMs-contact.timestampMs),
              (25...67).contains(release.timestampMs-firstRelease.timestampMs),
              measured.allSatisfy({ b in
                  [b.x,b.y,b.width,b.height,b.confidence].allSatisfy(\.isFinite)
                    && b.confidence >= 0.7 && b.width > 0 && b.height > 0
                    && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                    && b.y-b.height/2 >= 0 && b.y+b.height/2 <= (imageBottoms[b.frameIndex] ?? 1)
              }), measured.map(\.height).max()! <= 1.25*measured.map(\.height).min()!,
              measured.map(\.width).max()! <= 1.25*measured.map(\.width).min()!,
              incoming.y-approach.y >= 0.0035, contact.y >= incoming.y,
              contact.y-approach.y >= max(0.007,0.15*contact.height),
              contact.y-firstRelease.y >= max(0.007,0.2*contact.height),
              firstRelease.y-release.y >= 0.0035,
              contact.y-release.y >= max(0.02,0.35*contact.height) else { return nil }
        rawReboundProbeFrame = contact.frameIndex
        let fall = (contact.y-approach.y)/Double(contact.timestampMs-approach.timestampMs)*1000
        let rise = (contact.y-release.y)/Double(release.timestampMs-contact.timestampMs)*1000
        let impact = TrajectoryPoint(frameIndex: contact.frameIndex, timestampMs: contact.timestampMs,
            x: contact.x, y: contact.y, vy: fall, confidence: contact.confidence, valid: true, motion: .falling)
        let confirmation = TrajectoryPoint(frameIndex: release.frameIndex, timestampMs: release.timestampMs,
            x: release.x, y: release.y, vy: -rise, confidence: release.confidence, valid: true, motion: .rising)
        guard let touch = evaluate(apex: impact, confirmation: confirmation, arcTopY: approach.y,
            impulse: fall+rise, requiresMeasuredFoot: true) else { return nil }
        resetArc(restartTopY: release.y)
        touches.append(touch); lastTouchMs = touch.timestampMs
        return touch
    }

    /// At the end of a measured run, asymmetric smoothing can flatten two
    /// genuine release views. Do not extend the track: require the actual
    /// approach, impact and TWO rising observations, all fully in the image.
    /// The ordinary region/body/ground/hand/holding gates still decide legality.
    private func confirmMeasuredTerminalRebound(before missing: TrajectoryPoint) -> Touch? {
        guard config.recoversMeasuredTerminalRebound == true, armed,
              allowsBodyContact != nil, rejectsHandContact != nil,
              let last = lastValidPoint, (1...67).contains(missing.timestampMs-last.timestampMs) else { return nil }
        let views = observedBalls.values.filter {
            (0...201).contains(last.timestampMs-$0.timestampMs)
        }.sorted { $0.timestampMs < $1.timestampMs }
        guard views.count >= 4, let release = views.last, release.timestampMs == last.timestampMs else { return nil }
        let earlierRelease = views[views.count-2], contact = views[views.count-3], approach = views[views.count-4]
        let measured = [approach,contact,earlierRelease,release]
        guard zip(measured,measured.dropFirst()).allSatisfy({
            (25...67).contains($1.timestampMs-$0.timestampMs) && $1.frameIndex == $0.frameIndex+1
        }), measured.allSatisfy({ b in
            [b.x,b.y,b.width,b.height,b.confidence].allSatisfy(\.isFinite)
                && b.confidence >= 0.7 && b.width > 0 && b.height > 0
                && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                && b.y-b.height/2 >= 0 && b.y+b.height/2 <= (imageBottoms[b.frameIndex] ?? 1)
        }), measured.map(\.height).max()! <= 1.35*measured.map(\.height).min()!,
            measured.map(\.width).max()! <= 1.35*measured.map(\.width).min()!,
            contact.y-approach.y >= max(0.007,0.2*contact.height),
            contact.y-earlierRelease.y >= max(0.0035,0.05*contact.height),
            earlierRelease.y > release.y,
            contact.y-release.y >= max(0.02,0.35*contact.height) else { return nil }
        let fall = (contact.y-approach.y)/Double(contact.timestampMs-approach.timestampMs)*1000
        let rise = (contact.y-release.y)/Double(release.timestampMs-contact.timestampMs)*1000
        let impact = TrajectoryPoint(frameIndex:contact.frameIndex,timestampMs:contact.timestampMs,
            x:contact.x,y:contact.y,vy:fall,confidence:contact.confidence,valid:true,motion:.falling)
        let confirmation = TrajectoryPoint(frameIndex:release.frameIndex,timestampMs:release.timestampMs,
            x:release.x,y:release.y,vy:-rise,confidence:release.confidence,valid:true,motion:.rising)
        guard let touch = evaluate(apex:impact,confirmation:confirmation,
            arcTopY: min(arcTopY ?? approach.y,approach.y),impulse:fall+rise) else { return nil }
        resetArc(restartTopY:release.y)
        touches.append(touch); lastTouchMs=touch.timestampMs
        return touch
    }

    private func confirmRise(at point: TrajectoryPoint) -> Touch? {
        guard armed, let a = apex else { return nil }
        let directionConfirmed = confirmedDirection(at: point, frames: risingRun, milliseconds: riseEvidenceMs)
        let measuredSlowRise = !directionConfirmed && hasMeasuredSlowRise(from: a, to: point)
        guard directionConfirmed || measuredSlowRise else { return nil }
        let shortRise = measuredSlowRise || a.y - point.y < config.minRiseAmplitude
        if shortRise {
            guard config.recoversMeasuredSmallArcs == true,
                  a.y - point.y >= config.minRiseAmplitude * 0.5,
                  // With only half the normal rise, require a stronger turn
                  // before spending contact-recheck capacity. A weak early
                  // wobble must wait for the normal rise; otherwise its image
                  // request can starve a real contact inside the rate limit.
                  peakFall + peakRise >= config.minTouchImpulse * 2,
                  smallRiseProbeFrame != a.frameIndex else { return nil }
            smallRiseProbeFrame = a.frameIndex
        }
        let touch = evaluate(apex: a, confirmation: point,
                             arcTopY: arcTopY ?? a.y, impulse: peakFall + peakRise,
                             requiresMeasuredFoot: shortRise)
        // A failed early probe must not consume the normal arc: its subsequent
        // rise can still provide the evidence required by the established path.
        if shortRise && touch == nil { return nil }
        resetArc(restartTopY: point.y)
        if let touch {
            touches.append(touch)
            lastTouchMs = touch.timestampMs
        }
        return touch
    }

    /// The smoothing threshold is a noise filter, not evidence that a measured
    /// ball did not rebound. Three actual, fully visible observations must show
    /// approach and departure before this path may ask the unchanged foot gate.
    private func hasMeasuredSlowRise(from apex: TrajectoryPoint, to point: TrajectoryPoint) -> Bool {
        guard config.recoversMeasuredSlowRise == true, point.motion == .unknown, point.vy <= 0,
              (66...134).contains(point.timestampMs-apex.timestampMs),
              let contact = observedBalls[apex.frameIndex], let release = observedBalls[point.frameIndex] else { return false }
        func valid(_ b: BallObservation) -> Bool {
            [b.x,b.y,b.width,b.height,b.confidence].allSatisfy(\.isFinite)
                && b.width > 0 && b.height > 0 && b.confidence >= 0.5
                && b.x-b.width/2 >= 0 && b.x+b.width/2 <= 1
                && b.y-b.height/2 >= 0 && b.y+b.height/2 <= (imageBottoms[b.frameIndex] ?? 1)
        }
        guard valid(contact), valid(release),
              contact.y-release.y >= max(config.minRiseAmplitude,0.1*contact.height) else { return false }
        return observedBalls.values.contains { before in
            let trio = [before,contact,release]
            return (40...134).contains(contact.timestampMs-before.timestampMs) && valid(before)
                && contact.y-before.y >= max(0.007,0.35*contact.height)
                && trio.map(\.height).max()! <= 1.35*trio.map(\.height).min()!
                && trio.map(\.width).max()! <= 1.35*trio.map(\.width).min()!
        }
    }

    private func confirmedDirection(at point: TrajectoryPoint, frames: Int, milliseconds: Double) -> Bool {
        guard point.motionEvidenceMs != nil else { return frames >= config.minStateFrames }
        // Preserve the evidence duration of two 30 FPS direction samples. The
        // tolerance only covers integer-millisecond timestamp rounding.
        return milliseconds >= Double(config.minStateFrames) * TimedTrajectory.referenceIntervalMs - 2
    }

    private func evaluate(apex: TrajectoryPoint, confirmation: TrajectoryPoint,
                          arcTopY: Double, impulse: Double, requiresMeasuredFoot: Bool = false) -> Touch? {
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
            evidence.candidateTimestampMs == apex.timestampMs &&
                (FootContactRules.confirms(before: evidence.before, contact: evidence.contact,
                    after: evidence.after, requireBalancedMotion: groundPolicy != .legacyCenter,
                    usesFourExposureWindow: evidence.usesFourExposureWindow == true,
                    rejectsWeakBelowAnkle: evidence.rejectsWeakBelowAnkle == true)
                    || (sparseGround && evidence.confirmsExtendedMotion)
                    || evidence.observedLegContactMs != nil
                    || evidence.adjacentFootContactMs != nil
                    || evidence.confirmsShallowToeRebound
                    || evidence.confirmsRaisedForefoot
                    || (evidence.compactGroundEvidence?.contactMs == apex.timestampMs
                        && evidence.compactGroundEvidence?.confirmsCompactFootContact == true))
        }
        func canCheckFootBeyondRegion(_ region: Region, measured: FootContactRules.Sample? = nil) -> Bool {
            let observed = observedBalls[apex.frameIndex]
            let measuredBall = config.usesRecheckedRegionContact == true ? measured.map {
                BallObservation(frameIndex: apex.frameIndex, timestampMs: $0.timestampMs,
                    x: $0.ballX, y: $0.ballY, width: $0.width, height: $0.height, confidence: $0.confidence)
            } : nil
            let aligned = config.recoversAlignedFootRegion == true && footConfirmed == true
                && footEvidence.map { evidence in
                    evidence.proposedContactMs == apex.timestampMs && measured == evidence.contact
                        && AdjacentFootContactRules.measuredEvidence(
                            [evidence.before, evidence.contact, evidence.after],
                            proposedMs: apex.timestampMs)?.contact == evidence.contact
                } == true
            guard config.recoversVisibleFootOutsideRegion == true,
                  let ball = measuredBall ?? observed,
                  ball.timestampMs == apex.timestampMs || aligned,
                  [ball.x,ball.y,ball.width,ball.height,ball.confidence].allSatisfy(\.isFinite),
                  ball.confidence >= 0.5, ball.width > 0, ball.height > 0,
                  ball.x-ball.width/2 >= 0, ball.x+ball.width/2 <= 1,
                  ball.y-ball.height/2 >= 0, ball.y+ball.height/2 <= 1 else { return false }
            // A detector's body box may end at the ankle while a measured toe
            // contact puts the ball center another radius outside it. Only an
            // already confirmed foot may use that radius; ordinary candidates
            // keep their established search region.
            let reach = config.recoversMeasuredSmallArcs == true && measured != nil && footConfirmed == true ? 1.5 : 1.0
            // Keep the exception local to the selected player. A remote ball
            // or an off-screen contact never gets a new eligibility route.
            if config.usesRecheckedRegionContact == true,
               (ball.x < region.xMin-config.roiMargin-reach*ball.width
                || ball.x > region.xMax+config.roiMargin+reach*ball.width
                || ball.y < region.yMin-config.roiMargin-ball.height
                || ball.y > region.yMax+config.roiMargin+ball.height) { return false }
            return apex.x >= region.xMin-config.roiMargin-reach*ball.width
                && apex.x <= region.xMax+config.roiMargin+reach*ball.width
                && apex.y >= region.yMin-config.roiMargin-ball.height
                && apex.y <= region.yMax+config.roiMargin+ball.height
        }
        func canRequestRecheckedRegion(_ region: Region) -> Bool {
            guard config.usesRecheckedRegionContact == true else { return false }
            // Nearby original observations bound the request. Only the actual
            // measured contact returned by the verifier can qualify it.
            return observedBalls.values.contains { ball in
                abs(ball.frameIndex-apex.frameIndex) <= config.supportWindowFrames
                    && ball.confidence >= 0.5 && ball.width > 0 && ball.height > 0
                    && apex.x >= region.xMin-config.roiMargin-ball.width
                    && apex.x <= region.xMax+config.roiMargin+ball.width
                    && apex.y >= region.yMin-config.roiMargin-ball.height
                    && apex.y <= region.yMax+config.roiMargin+ball.height
            }
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

        // A short-rise probe may otherwise retry the same physical rebound
        // when its rise grows. A complete floor proof is already conclusive;
        // only uncertain contact checks should request more evidence.
        if unliftedFloorRejectedFrame == apex.frameIndex { return reject(.groundBounce) }

        // A fixed fraction of the image rejected clear low keep-ups (25.6 px
        // at 1280 px). Scale to the observed ball, retaining the rise noise floor
        // and the existing impulse, support, ground and contact checks below.
        if fallAmplitude < requiredFall || requiresMeasuredFoot {
            guard config.recoversSmallVisibleContacts == true,
                  fallAmplitude >= config.minRiseAmplitude * (config.recoversMeasuredSmallArcs == true ? 0.5 : 1),
                  impulse >= config.minTouchImpulse,
                  hasDetectionSupport(apex.frameIndex),
                  let region = nearestRegion(apex.frameIndex),
                  let provider = footContactEvidence else { return reject(.amplitudeTooSmall) }
            footEvidence = provider(apex.frameIndex)
            footConfirmed = footEvidence.map(confirmsFoot) ?? false
            guard footConfirmed == true,
                  footEvidence.map({ canCheckFootBeyondRegion(region, measured: $0.contact) }) == true
            else { return reject(.amplitudeTooSmall) }
        }
        if impulse < config.minTouchImpulse { return reject(.insufficientImpulse) }

        if let ground,
           apex.y >= ground - config.groundTolerance
            || (observedBottom.map { $0 >= ground - boundaryTolerance } ?? false) {
            let region = nearestRegion(apex.frameIndex)
            let eligible = hasDetectionSupport(apex.frameIndex)
                && region.map { $0.contains(apex.x, apex.y, margin: config.roiMargin) || canCheckFootBeyondRegion($0) || canRequestRecheckedRegion($0) } == true
                && (lastTouchMs.map { apex.timestampMs - $0 >= config.touchCooldownMs } ?? true)
            if eligible, (footConfirmed == nil || config.recoversMeasuredSmallArcs != true),
               let provider = footContactEvidence {
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
            let measuredEligibility = config.recoversMeasuredSmallArcs == true && footConfirmed == true
                && footEvidence.map { canCheckFootBeyondRegion(region, measured: $0.contact) } == true
            guard measuredEligibility || canCheckFootBeyondRegion(region) || canRequestRecheckedRegion(region) else { return reject(.outsidePersonRegion) }
            if footConfirmed == nil, let provider = footContactEvidence {
                footEvidence = provider(apex.frameIndex)
                footConfirmed = footEvidence.map(confirmsFoot) ?? false
            }
            guard footConfirmed == true,
                  canCheckFootBeyondRegion(region) || footEvidence.map({ canCheckFootBeyondRegion(region, measured: $0.contact) }) == true
            else { return reject(.outsidePersonRegion) }
        }

        // Check the whole lower-body area, not just a person-box floor line.
        // Perspective and trajectory smoothing can put a real floor impact
        // above that line. This gate requires positive, sustained pose evidence.
        if (groundPolicy == .plantedFeet || groundPolicy == .corroboratedFeet), let person = nearestPerson(apex.frameIndex),
           apex.y + (ballHeights[apex.frameIndex] ?? 0)/2 >= person.bottom-person.height*0.35,
           let provider = groundContactEvidence {
            groundEvidence = provider(apex.frameIndex)
            // The floor line comes from the counter's stabilized ground
            // estimate; the pose evidence only establishes the stance.
            let floorLineReached = ground.map { floor in
                observedBottom.map { $0 >= floor-boundaryTolerance } ?? false
            } ?? false
            plantedFeetConfirmed = groundEvidence.map {
                $0.contactMs == apex.timestampMs && ($0.confirmsGroundContact(
                    corroboratingWeakAnkles: groundPolicy == .corroboratedFeet,
                    cadenceAware: sparseGround)
                    || (floorLineReached && $0.confirmsBallBesideFeet))
            } ?? false
            // A floor rebound without pre-impact lift cannot be rescued by
            // chasing the ball sideways or lifting the foot after it bounced.
            // Preserve a separately resolved legal leg impact and its own
            // ground clearance. This proof uses only existing saved views.
            if groundEvidence?.contactMs == apex.timestampMs,
               groundEvidence.map({ $0.unliftedFloorReboundMs != nil
                   || $0.corroboratedFloorReboundMs != nil
                   || (config.rejectsDescendingFloorRebound == true
                       && MeasuredFootImpactRules.descendingFloorRebound($0) != nil) }) == true,
               footEvidence?.confirmsAlignedLegGroundClearance != true {
                unliftedFloorRejectedFrame = apex.frameIndex
                plantedFeetConfirmed = true
                return reject(.groundBounce)
            }
            if plantedFeetConfirmed == true || groundEvidence?.needsPositiveFootContact == true
                || (config.requiresDistantLowFootProof == true && groundEvidence?.hasDistantLowBall == true) {
                // A resolved kick can still rescue the contact. Reuse a prior
                // check when the body-box ground gate already requested it.
                if footConfirmed == nil, let provider = footContactEvidence {
                    footEvidence = provider(apex.frameIndex)
                    footConfirmed = footEvidence.map(confirmsFoot) ?? false
                }
                // A confirmed floor contact needs a real foot movement to be
                // overturned, not a hip-relative artefact of pose jitter.
                let jitterOnly = plantedFeetConfirmed == true && groundEvidence?.requiresMovingAnkleForRescue == true
                    && !(footEvidence.map { FootContactRules.ankleTravels($0)
                        || $0.confirmsAlignedLegGroundClearance } ?? false)
                    && !(config.recoversBriefToeLift == true
                        && groundEvidence.map(MeasuredFootImpactRules.briefToeLift) == true)
                if footConfirmed != true || jitterOnly {
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
