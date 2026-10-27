import CoreVideo
import Foundation

/// Inspect only candidate contacts, using a bounded cache of small images. No
/// pose inference runs in preview or on every camera frame. A suspected floor
/// contact may reuse three buffered views to establish approach and separation
/// at a foot; the same poses also serve the hand veto. Uncertain/missing
/// pose is not evidence of a hand; the trajectory gates still decide the touch.
nonisolated final class JugglingContactVerifier: ContactEvidenceProviding {
    /// Diagnostic opt-out is also included in the analysis cache signature.
    static let enabled = CountingPolicy.current.verifiesContacts
    private var usesContactEvidenceV16 = false
    private var requiresPositiveLowContact = false
    private var usesFloorEvidenceV18 = false
    private var usesFloorRescueV19 = false
    private var usesToeContactV20 = false
    func configure(policy: CountingPolicy) {
        usesContactEvidenceV16 = policy.body.usesContactEvidence
        // The gap gate rejects an ankle-height reversal with a detection hole at
        // impact unless a kick is proven. With the impact-window repair it rarely
        // fires on a legal touch; without it (compact tier) it removed nine
        // labelled low touches for four reviewed bounces across every saved
        // compact trace, so the compact tier relies on the positive floor proofs
        // (planted feet, below feet, stationary hole, deep contact) instead.
        requiresPositiveLowContact = policy.body.usesImpactWindow && RFContactRecheckTier.current == .full
        usesFloorEvidenceV18 = policy.body.usesFloorEvidence
        usesToeContactV20 = policy.body == .toeContactV20
        usesFloorRescueV19 = policy.body == .floorRescueV19 || usesToeContactV20
    }
    private typealias Frame = ContactObservationStore.Frame
    private typealias Pose = ContactObservationStore.Pose
    private let observations: ContactObservationStore
    private var frames: [Frame] { observations.immediateFrames }
    private var handCache: [Int: Bool] = [:]
    private var bodyFailures: [Int: RestrictedTouchPolicy.Failure] = [:]
    private var alignedFootFrames: [Int: Int] = [:]
    var handPoseRequests: Int { observations.handPoseRequests }
    private(set) var footChecks = 0
    private(set) var footRecoveries = 0
    private(set) var footCheckMS = 0.0
    var poseRequests: Int { observations.poseRequests }
    var poseCacheHits: Int { observations.poseCacheHits }
    private(set) var checkedContacts = 0
    private(set) var rejectedContacts = 0
    private(set) var lastCheckMS = 0.0
    private(set) var totalCheckMS = 0.0
    var warmUpMS: Double { observations.warmUpMS }
    var peakBufferedFrames: Int { observations.peakBufferedFrames }
    var lastError: String? { observations.lastError }
    private var isDiagnosing = false
    private var evidencePlayer: ActivePlayerSelection?
    var requiresGroundHeightEvidence = true
    #if DEBUG
    var usesSelectedPoseRecovery = false
    private let selectedPoseRecovery = SelectedPlayerPoseRecovery()
    var poseRecoveryMetrics: [String: Double] {
        ["requests": Double(selectedPoseRecovery.requests), "recoveredFrames": Double(selectedPoseRecovery.recovered),
         "milliseconds": selectedPoseRecovery.milliseconds]
    }
    var onPoseRecoveryEvidence: ((Int, Int, [FootPoseSample]) -> Void)?
    /// Explicit replay harness only; no pixels, no work unless a reader is attached.
    var onContactEvidence: ((Int, Int, [FootPoseSample]) -> Void)?
    var onPixelTrack: ((Int, [TrackedFootContactRules.Observation], Int?, Double) -> Void)?
    #endif
    init(observations: ContactObservationStore = ContactObservationStore()) {
        self.observations = observations
    }

    func discardFrames() {
        observations.discardFrames()
        #if DEBUG
        selectedPoseRecovery.retain([])
        #endif
        handCache.removeAll(keepingCapacity: true)
        bodyFailures.removeAll(keepingCapacity: true)
        alignedFootFrames.removeAll(keepingCapacity: true)
    }

    func retainContactFrames(around index: Int?) { observations.retainContactFrames(around: index) }

    func reset() {
        discardFrames()
        observations.reset()
        #if DEBUG
        selectedPoseRecovery.reset()
        #endif
        footChecks = 0
        footRecoveries = 0
        footCheckMS = 0
        checkedContacts = 0
        rejectedContacts = 0
        lastCheckMS = 0
        totalCheckMS = 0
    }

    func warmUp() { observations.warmUp() }

    func store(_ pixels: CVPixelBuffer, frameIndex: Int, timestampMs: Int,
               ball: Detection?, orientLandscapeAsPortrait: Bool = true, player: ActivePlayerSelection? = nil) {
        guard lastError == nil else { return }
        observations.store(pixels, frameIndex: frameIndex, timestampMs: timestampMs,
                           ball: ball, orientLandscapeAsPortrait: orientLandscapeAsPortrait, player: player)
        let retained = Set(frames.map(\.index))
        #if DEBUG
        selectedPoseRecovery.retain(Set(observations.frames.map(\.index)))
        #endif
        handCache = handCache.filter { retained.contains($0.key) }
        bodyFailures = bodyFailures.filter { retained.contains($0.key) }
        alignedFootFrames = alignedFootFrames.filter { retained.contains($0.key) && retained.contains($0.value) }
    }

    /// Only a detected ball and usable pose at the candidate contact can satisfy
    /// the restricted experiment. Missing evidence never defaults to acceptance.
    func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool {
        let previousPlayer = evidencePlayer
        evidencePlayer = previousPlayer ?? observations.selection(at: frameIndex)
        defer { evidencePlayer = previousPlayer }
        if policy == .unrestricted { return true }
        if let evidencePlayer, !evidencePlayer.canMatchPose {
            bodyFailures[frameIndex] = .missingPose
            return false
        }
        bodyFailures.removeValue(forKey: frameIndex)
        alignedFootFrames.removeValue(forKey: frameIndex)
        if !policy.usesClearHands { return allowsHeadKneeFootContact(at: frameIndex) }
        guard lastError == nil else {
            bodyFailures[frameIndex] = .missingPose
            return false
        }
        guard let frame = frames.first(where: { $0.index == frameIndex }) else {
            if policy.usesObservedImpact, recoverObservedLeg(at: frameIndex) { return true }
            bodyFailures[frameIndex] = bodyFailures[frameIndex] ?? .missingBall
            return false
        }
        guard let pose = pose(for: frame) else {
            bodyFailures[frameIndex] = .missingPose
            return false
        }
        // Clear hands can establish eligibility without distinguishing chest
        // from a raised foot in 2D. Existing positive leg-motion evidence stays
        // available when an arm merely projects close to a legitimate kick.
        if RestrictedTouchPolicy.region(ball: .init(x: frame.ball.x, y: frame.ball.y),
            width: frame.ball.width, height: frame.ball.height, joints: pose.joints,
            imageAspect: Double(CVPixelBufferGetWidth(frame.pixels)) / Double(CVPixelBufferGetHeight(frame.pixels))) != nil { return true }
        let samples = contactSamples(around: frame)
        #if DEBUG
        onContactEvidence?(frameIndex, frame.timestampMs, samples)
        #endif
        let failure = ClearHandsContactRules.failure(samples.map(\.pose), at: frame.timestampMs)
        if failure != nil, lastError == nil,
           allowsHeadKneeFootContact(at: frameIndex, recordEvidence: false) { return true }
        if failure == .lowContactNeedsFootEvidence, lastError == nil,
           footEvidence(at: frameIndex)?.confirms == true { return true }
        if failure != nil, policy.usesMovingFoot, lastError == nil,
           let time = MovingFootContactRules.contactTime(samples, at: frame.timestampMs, usePoseContinuity: policy.usesPoseContinuity),
           let aligned = frames.first(where: { $0.timestampMs == time }) {
            alignedFootFrames[frameIndex] = aligned.index
            return true
        }
        if failure != nil, policy.usesObservedJointContinuity, lastError == nil {
            let corroborated = ContactPoseContinuity.corroborate(samples)
            if ClearHandsContactRules.failure(corroborated.map(\.pose), at: frame.timestampMs) == nil { return true }
            if let time = MovingFootContactRules.contactTime(corroborated, at: frame.timestampMs),
               let aligned = frames.first(where: { $0.timestampMs == time }) {
                alignedFootFrames[frameIndex] = aligned.index
                return true
            }
        }
        if failure != nil, policy.usesTimedFootMotion, lastError == nil {
            let selected = ContactFrameWindow.motionIndices(
                observations.frames.map { .init(index: $0.index, timestampMs: $0.timestampMs) },
                around: .init(index: frame.index, timestampMs: frame.timestampMs))
            let timed = contactSamples(observations.frames.filter { selected.contains($0.index) })
            #if DEBUG
            onContactEvidence?(frameIndex, frame.timestampMs, timed)
            #endif
            // Only positive foot motion can recover this rejection. The hand
            // clearance test above still uses the immediate impact neighbors;
            // a clearer, distant wrist must not hide a real hand contact.
            if let time = MovingFootContactRules.contactTime(ContactPoseContinuity.corroborate(timed),
                at: frame.timestampMs, allowsLiftedFoot: true),
               let aligned = frames.first(where: { $0.timestampMs == time }) {
                alignedFootFrames[frameIndex] = aligned.index
                return true
            }
            // Leg evidence is independent of arm clearance in the current policy,
            // including missing shoulders or insufficient immediate arm views.
            // Recovery still needs observed leg motion, ball approach/release and
            // support clearance. Confirmed hand and handling vetoes run afterward,
            // including at the aligned physical contact when it differs. An
            // ambiguous chest with no positive leg evidence remains ineligible.
            if policy.allowsObservedLegRecovery(after: failure),
               let time = ObservedLegContactRules.contactTime(timed, at: frame.timestampMs,
                    usesTemporalEvidence: policy.usesTemporalEvidence),
               let aligned = frames.first(where: { $0.timestampMs == time }) {
                alignedFootFrames[frameIndex] = aligned.index
                return true
            }
            if (policy == .legReboundV13 || policy.usesRaisedFoot), policy.allowsObservedLegRecovery(after: failure) {
                let indices = ContactFrameWindow.reboundIndices(
                    observations.frames.map { .init(index: $0.index, timestampMs: $0.timestampMs) },
                    around: .init(index: frame.index, timestampMs: frame.timestampMs))
                let rebound = contactSamples(observations.frames.filter { indices.contains($0.index) })
                #if DEBUG
                onContactEvidence?(frameIndex, frame.timestampMs, rebound)
                #endif
                // Recovery uses only already arrived exposures. Arm uncertainty
                // is not kick evidence: require a measured leg/ball rebound.
                let impact = ObservedLegContactRules.contactTime(rebound, at: frame.timestampMs,
                    usesTemporalEvidence: true, usesCadenceWindow: true, allowsNearSupportFoot: policy.usesRaisedFoot,
                    usesImageSupport: policy == .footEvidenceV15 || policy.usesContactEvidence)
                    ?? RaisedKneeReboundRules.contactTime(rebound, at: frame.timestampMs)
                    ?? (policy.usesRaisedFoot ? RaisedFootReboundRules.contactTime(rebound, at: frame.timestampMs) : nil)
                    ?? (policy.usesContactEvidence ? ReciprocalJointContactRules.contactTime(rebound, at: frame.timestampMs) : nil)
                if let impact, let aligned = frames.first(where: { $0.timestampMs == impact }),
                   groundEvidence(at: aligned.index, timed: true)?.confirmsGroundContact(corroboratingWeakAnkles: true) != true,
                   handlingEvidence(at: aligned.index)?.state != .held, lastError == nil {
                    alignedFootFrames[frameIndex] = aligned.index
                    return true
                }
            }
            if policy.usesTemporalEvidence, failure == .handsUncertain {
                let supported = TemporalContactEvidence.corroborateWrists(timed)
                // Clear only the original immediate impact views. A sampled
                // history view must never replace a hidden wrist at impact.
                let immediate = samples.map { view in
                    supported.first { $0.pose.timestampMs == view.pose.timestampMs } ?? view
                }
                if ClearHandsContactRules.failure(immediate.map(\.pose),at:frame.timestampMs) == nil { return true }
            }
            if policy.bodyTracksFootPixels, failure == .handsUncertain {
                let stamps = observations.frames.map { ContactFrameWindow.Stamp(index:$0.index,timestampMs:$0.timestampMs) }
                let pixelIndices = ContactFrameWindow.trackedFootIndices(
                    stamps,around:.init(index:frame.index,timestampMs:frame.timestampMs))
                let pixelFrames = observations.frames.filter { pixelIndices.contains($0.index) }
                let pixelSamples = contactSamples(pixelFrames)
                #if DEBUG
                onContactEvidence?(frameIndex,frame.timestampMs,pixelSamples)
                #endif
                if let plan = TrackedFootContactRules.plan(pixelSamples,at:frame.timestampMs) {
                    let start = ProcessInfo.processInfo.systemUptime
                    let track = (try? ContactFootMotionTracker.track(pixelFrames,plan:plan)) ?? []
                    let time = TrackedFootContactRules.contactTime(pixelSamples,track:track,plan:plan,at:frame.timestampMs)
                    #if DEBUG
                    onPixelTrack?(frameIndex,track,time,(ProcessInfo.processInfo.systemUptime-start)*1000)
                    #endif
                    if let time, let aligned = frames.first(where: { $0.timestampMs == time }) {
                        alignedFootFrames[frameIndex] = aligned.index
                        return true
                    }
                }
            }
        }
        #if DEBUG
        if failure != nil, usesSelectedPoseRecovery, lastError == nil,
           recoverRaisedShin(at: frame) { return true }
        #endif
        // The same positive foot evidence used for low contacts can establish
        // a raised kick despite an arm projecting nearby. Ground has already
        // been checked; hand and holding vetoes still run after eligibility.
        if usesToeContactV20, policy.allowsObservedLegRecovery(after: failure), lastError == nil,
           footEvidence(at: frameIndex)?.confirms == true { return true }
        bodyFailures[frameIndex] = lastError == nil ? failure : .missingPose
        return lastError == nil && failure == nil
    }

    #if DEBUG
    private func recoverRaisedShin(at contact: Frame) -> Bool {
        guard let baseline = pose(for: contact),
              SelectedPlayerPoseRecovery.direction(baseline: baseline,player: contact.player,
                aspect: Double(CVPixelBufferGetWidth(contact.pixels))/Double(CVPixelBufferGetHeight(contact.pixels))) != nil
        else { return false }
        let indices = ContactFrameWindow.reboundIndices(
            observations.frames.map { .init(index: $0.index,timestampMs: $0.timestampMs) },
            around: .init(index: contact.index,timestampMs: contact.timestampMs))
        let samples: [FootPoseSample] = observations.frames.filter { indices.contains($0.index) }.map { frame in
            let original = pose(for: frame) ?? Pose()
            let recovered: Pose
            if frame.player?.id == contact.player?.id, frame.player?.state == .locked {
                recovered = SelectedPlayerPoseRecovery.legScore(original) > 0 ? original
                    : (selectedPoseRecovery.pose(for: frame,baseline: original) ?? Pose())
            } else { recovered = Pose() }
            return .init(pose: .init(timestampMs: frame.timestampMs,ball: .init(x: frame.ball.x,y: frame.ball.y),
                width: frame.ball.width,height: frame.ball.height,confidence: frame.ball.score,
                imageAspect: Double(CVPixelBufferGetWidth(frame.pixels))/Double(CVPixelBufferGetHeight(frame.pixels)),
                joints: recovered.joints),ankles: recovered.ankles,landmarks: recovered.landmarks)
        }
        onPoseRecoveryEvidence?(contact.index,contact.timestampMs,samples)
        guard let time = RaisedShinContactRules.contactTime(samples,at: contact.timestampMs),
              let aligned = frames.first(where: { $0.timestampMs == time }),
              groundEvidence(at: aligned.index,timed: true)?.confirmsGroundContact(corroboratingWeakAnkles: true) != true,
              handlingEvidence(at: aligned.index)?.state != .held,
              !rejectsHandInWindow(at: aligned.index), lastError == nil else { return false }
        alignedFootFrames[contact.index] = aligned.index
        return true
    }
    #endif

    /// A reversal can land in a short detector hole. Recovery needs two real
    /// views supporting leg eligibility and foot movement; proximity or missing
    /// hands alone cannot qualify. All samples keep their original positions.
    private func recoverObservedLeg(at frameIndex: Int) -> Bool {
        guard let time = observations.timestamp(at: frameIndex) else { return false }
        guard let before = frames.filter({ $0.timestampMs < time }).max(by: { $0.timestampMs < $1.timestampMs }),
              let after = frames.filter({ $0.timestampMs > time }).min(by: { $0.timestampMs < $1.timestampMs }),
              time-before.timestampMs <= 133, after.timestampMs-time <= 100,
              after.timestampMs-before.timestampMs <= 200 else { return false }
        // Only the real bracketing exposures need pose inference here. The
        // floor checks below lazily request their own longer window if needed.
        let samples = contactSamples([before,after])
        #if DEBUG
        onContactEvidence?(frameIndex, time, samples)
        #endif
        guard let impact = ObservedGapContactRules.contactTime(samples, at: time),
              let aligned = frames.first(where: { $0.timestampMs == impact }), lastError == nil else { return false }
        // Apply both ground and hand evidence at the real bracket, including
        // the preceding exposure; recovery cannot move a veto past impact.
        for index in [aligned.index,before.index] {
            if groundEvidence(at: index, timed: true)?.confirmsGroundContact(corroboratingWeakAnkles: true) == true {
                bodyFailures[frameIndex] = .lowContactNeedsFootEvidence
                return false
            }
            if rejectsHandInWindow(at: index) || handlingEvidence(at: index)?.state == .held {
                bodyFailures[frameIndex] = .handsNearBall
                return false
            }
        }
        alignedFootFrames[frameIndex] = aligned.index
        return true
    }

    private func contactSamples(around frame: Frame) -> [FootPoseSample] {
        contactSamples(frames.filter {
            (frame.index-3...frame.index+3).contains($0.index)
                && (-100...150).contains($0.timestampMs-frame.timestampMs)
        })
    }

    private func contactSamples(_ views: [Frame]) -> [FootPoseSample] {
        views.map { view in
            let pose = self.pose(for: view) ?? Pose()
            return .init(pose: .init(timestampMs: view.timestampMs, ball: .init(x: view.ball.x, y: view.ball.y),
                width: view.ball.width, height: view.ball.height, confidence: view.ball.score,
                imageAspect: Double(CVPixelBufferGetWidth(view.pixels)) / Double(CVPixelBufferGetHeight(view.pixels)),
                joints: pose.joints), ankles: pose.ankles, landmarks: pose.landmarks)
        }
    }

    /// The previous policy also supplies positive leg evidence when the new
    /// clearance test is uncertain. Absence of a hand alone never qualifies.
    private func allowsHeadKneeFootContact(at frameIndex: Int, recordEvidence: Bool = true) -> Bool {
        guard lastError == nil, let frame = frames.first(where: { $0.index == frameIndex }),
              let pose = pose(for: frame) else { return false }
        if RestrictedTouchPolicy.region(ball: .init(x: frame.ball.x, y: frame.ball.y),
            width: frame.ball.width, height: frame.ball.height, joints: pose.joints,
            imageAspect: Double(CVPixelBufferGetWidth(frame.pixels)) / Double(CVPixelBufferGetHeight(frame.pixels))) != nil { return true }
        // Reuse only already-buffered contact images. No extra lookahead or
        // every-frame pose work; the normal hand veto still runs after this.
        let nearby = frames.filter {
            (frameIndex-1...frameIndex+3).contains($0.index)
                && (-50...150).contains($0.timestampMs-frame.timestampMs)
        }
        let samples = nearby.compactMap { view -> ContactPoseSample? in
            guard let pose = self.pose(for: view) else { return nil }
            return .init(timestampMs: view.timestampMs, ball: .init(x: view.ball.x, y: view.ball.y),
                width: view.ball.width, height: view.ball.height, confidence: view.ball.score,
                imageAspect: Double(CVPixelBufferGetWidth(view.pixels)) / Double(CVPixelBufferGetHeight(view.pixels)),
                joints: pose.joints)
        }
        guard lastError == nil else { return false }
        if RaisedKneeContactRules.confirms(samples, at: frame.timestampMs) { return true }
        let footSamples = contactSamples(around: frame)
        #if DEBUG
        if recordEvidence { onContactEvidence?(frameIndex, frame.timestampMs, footSamples) }
        #endif
        return lastError == nil && RaisedFootContactRules.confirms(footSamples, at: frame.timestampMs)
    }

    func rejectsHandContact(at frameIndex: Int) -> Bool {
        let previousPlayer = evidencePlayer
        evidencePlayer = previousPlayer ?? observations.selection(at: frameIndex)
        defer { evidencePlayer = previousPlayer }
        if rejectsHandInWindow(at: frameIndex) { return true }
        if let aligned = alignedFootFrames[frameIndex], aligned != frameIndex {
            return rejectsHandInWindow(at: aligned)
        }
        return false
    }

    private func rejectsHandInWindow(at frameIndex: Int) -> Bool {
        guard lastError == nil else { return false }
        // Never substitute a frame far from the reversal. Two nearby views
        // must agree, so one misplaced wrist cannot remove a genuine touch.
        guard let first = frames.min(by: { abs($0.index - frameIndex) < abs($1.index - frameIndex) }),
              abs(first.index - frameIndex) <= 1,
              let second = frames.first(where: { $0.index > first.index && $0.index <= first.index + 2
                  && $0.timestampMs > first.timestampMs && $0.timestampMs - first.timestampMs <= 100 }) else { return false }
        checkedContacts += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            lastCheckMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            totalCheckMS += lastCheckMS
        }
        let firstHand = isHand(first)
        let secondHand = (firstHand || isTorsoHandCandidate(first)) ? isHand(second) : false
        var rejected = firstHand && secondHand
        // A palm can be hidden by the ball in one exposure. For the ambiguous
        // torso case only, accept two agreeing views out of three, still within
        // 100 ms of the reversal. Never extend this tolerance to leg contacts.
        if !rejected, (firstHand || secondHand), isTorsoHandCandidate(first),
           let third = frames.first(where: { $0.index > second.index && $0.index <= first.index + 3
               && $0.timestampMs > second.timestampMs && $0.timestampMs - first.timestampMs <= 100 }) {
            rejected = isHand(third)
        }
        if rejected { rejectedContacts += 1 }
        return rejected
    }

    /// The body gate runs before the hand veto. For the debug display only,
    /// also inspect those blocked candidates so a body rejection is never
    /// mislabeled as a hand without actual hand evidence. No every-frame work.
    func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent {
        isDiagnosing = true
        defer { isDiagnosing = false }
        let hand = decision.handRejected == true ||
            (decision.rejection == .disallowedBodyContact && rejectsHandContact(at: decision.frameIndex))
        var failure: RestrictedTouchPolicy.Failure?
        if decision.rejection == .disallowedBodyContact {
            failure = .missingBall
            if let frame = frames.first(where: { $0.index == decision.frameIndex }) {
                failure = .missingPose
                if let pose = pose(for: frame) {
                    failure = RestrictedTouchPolicy.assess(ball: .init(x: frame.ball.x, y: frame.ball.y),
                        width: frame.ball.width, height: frame.ball.height, joints: pose.joints,
                        imageAspect: Double(CVPixelBufferGetWidth(frame.pixels)) / Double(CVPixelBufferGetHeight(frame.pixels))).failure
                }
            }
            failure = bodyFailures[decision.frameIndex] ?? failure
        }
        return .init(frameIndex: decision.frameIndex, time: Double(decision.timestampMs) / 1000,
            rejection: decision.rejection, handConfirmed: hand, bodyFailure: failure, ball: ball, player: observations.selection(at: decision.frameIndex))
    }

    /// Uses only frames already buffered when the counter requests a decision.
    /// Exact observed contact, confidence and bounded time/size guards precede Vision.
    func footEvidence(at frameIndex: Int) -> FootContactEvidence? {
        let previousPlayer = evidencePlayer
        evidencePlayer = previousPlayer ?? observations.selection(at: frameIndex)
        defer { evidencePlayer = previousPlayer }
        guard lastError == nil, let contact = frames.first(where: { $0.index == frameIndex }) else { return nil }
        let before = frames.filter { (40...130).contains(contact.timestampMs - $0.timestampMs) }
            .min { abs(contact.timestampMs - $0.timestampMs - 100) < abs(contact.timestampMs - $1.timestampMs - 100) }
        let after = frames.filter { (40...130).contains($0.timestampMs - contact.timestampMs) }
            .min { abs($0.timestampMs - contact.timestampMs - 100) < abs($1.timestampMs - contact.timestampMs - 100) }
        guard let before, let after else { return nil }
        let trio = [before, contact, after]
        guard trio.allSatisfy({ $0.ball.score >= 0.5 }),
              trio.map({ $0.ball.height }).max()! <= 1.35 * trio.map({ $0.ball.height }).min()!,
              trio.map({ $0.ball.width }).max()! <= 1.35 * trio.map({ $0.ball.width }).min()! else { return nil }
        footChecks += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer { footCheckMS += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        var samples: [FootContactRules.Sample] = []
        for frame in trio {
            guard let pose = pose(for: frame) else { return nil }
            let b = frame.ball
            samples.append(.init(timestampMs: frame.timestampMs, ballX: b.x, ballY: b.y,
                width: b.width, height: b.height, confidence: b.score, ankles: pose.ankles, hips: pose.hips))
        }
        var evidence = FootContactEvidence(before: samples[0], contact: samples[1], after: samples[2])
        // At 15 FPS, the first release view can still overlap the moving foot.
        // Use one later REAL view if it is already in the bounded buffer. Dense
        // 30 FPS decisions normally have no such view; no extra lookahead is added.
        if !evidence.confirms,
           let later = frames.filter({ (131...167).contains($0.timestampMs-contact.timestampMs) })
                .min(by: { $0.timestampMs < $1.timestampMs }),
           later.ball.score >= 0.5, let pose = pose(for: later) {
            let b = later.ball
            evidence.continuation = .init(timestampMs: later.timestampMs, ballX: b.x, ballY: b.y,
                width: b.width, height: b.height, confidence: b.score, ankles: pose.ankles, hips: pose.hips)
        }
        if evidence.confirms { footRecoveries += 1 }
        return evidence
    }

    func groundEvidence(at frameIndex: Int, timed: Bool = false) -> GroundContactEvidence? {
        let previousPlayer = evidencePlayer
        evidencePlayer = previousPlayer ?? observations.selection(at: frameIndex)
        defer { evidencePlayer = previousPlayer }
        guard lastError == nil, let contact = frames.first(where: { $0.index == frameIndex }) else { return nil }
        let selected = timed ? ContactFrameWindow.groundIndices(
            observations.frames.map { .init(index: $0.index, timestampMs: $0.timestampMs) },
            around: .init(index: frameIndex, timestampMs: contact.timestampMs)) : []
        let views = timed ? observations.frames.filter { selected.contains($0.index) } : frames.filter {
            (frameIndex-9...frameIndex+3).contains($0.index)
                && (-350...150).contains($0.timestampMs-contact.timestampMs)
        }
        let samples = views.compactMap { frame -> GroundContactEvidence.Sample? in
            guard let pose = pose(for: frame) else { return nil }
            let ball = frame.ball
            return .init(timestampMs: frame.timestampMs, ballX: ball.x, ballY: ball.y,
                width: ball.width, height: ball.height, confidence: ball.score,
                imageAspect: Double(CVPixelBufferGetWidth(frame.pixels))/Double(CVPixelBufferGetHeight(frame.pixels)),
                ankles: pose.ankles, hips: pose.hips)
        }
        return .init(contactMs: contact.timestampMs, samples: samples, checksBallBelowFeet: timed ? true : nil,
                     requiresLowBallCenter: requiresGroundHeightEvidence ? true : nil,
                     usesLocalImpactSize: usesContactEvidenceV16 ? true : nil,
                     requiresPositiveLowContact: requiresPositiveLowContact
                        && GroundContactEvidence.hasImpactTrackingGap(contactMs: contact.timestampMs,
                            originalTimestampsMs: observations.frames.filter { !$0.isContactRecheck }.map(\.timestampMs),
                            missingBallTimestampsMs: observations.originalMissingBallTimestampsMs)
                        ? true : nil,
                     toleratesApproachGap: usesFloorEvidenceV18 ? true : nil,
                     checksBallBesideFeet: usesFloorEvidenceV18 ? true : nil,
                     toleratesPlantedApproachGap: usesFloorRescueV19 ? true : nil,
                     requiresMovingAnkleForRescue: usesFloorRescueV19 ? true : nil,
                     allowsStationaryHole: usesFloorRescueV19 ? true : nil,
                     checksDeepFloorContact: usesFloorRescueV19 ? true : nil,
                     checksCompactFootContact: usesToeContactV20 ? true : nil)
    }

    /// Only proposals that passed the existing gates request this extra window.
    /// Reuses the same bounded images and cached poses, with no extra lookahead.
    func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence? {
        let previousPlayer = evidencePlayer
        evidencePlayer = previousPlayer ?? observations.selection(at: frameIndex)
        defer { evidencePlayer = previousPlayer }
        if !frames.contains(where: { $0.index == frameIndex }),
           let aligned = alignedFootFrames[frameIndex], aligned != frameIndex,
           let time = observations.timestamp(at: frameIndex),
           let evidence = handlingEvidence(at: aligned) {
            return .init(contactMs: time, samples: evidence.samples, observedImpactMs: evidence.contactMs,
                         bridgesGripJitter: usesContactEvidenceV16 ? true : nil)
        }
        guard lastError == nil, let contact = frames.first(where: { $0.index == frameIndex }) else { return nil }
        let samples = frames.filter {
            (frameIndex-6...frameIndex+3).contains($0.index)
                && (-200...150).contains($0.timestampMs-contact.timestampMs)
        }.map { frame -> BallHandlingEvidence.Sample in
            let pose = self.pose(for: frame) ?? Pose()
            let ball = frame.ball
            return .init(timestampMs: frame.timestampMs, ball: .init(x: ball.x, y: ball.y),
                width: ball.width, height: ball.height, confidence: ball.score,
                imageAspect: Double(CVPixelBufferGetWidth(frame.pixels))/Double(CVPixelBufferGetHeight(frame.pixels)),
                wrists: pose.wrists)
        }
        guard lastError == nil else { return nil }
        return .init(contactMs: contact.timestampMs, samples: samples, bridgesGripJitter: usesContactEvidenceV16 ? true : nil)
    }

    private func isHand(_ frame: Frame) -> Bool {
        guard let pose = pose(for: frame) else { return false }
        if JugglingContactRules.isHand(ball: .init(x: frame.ball.x, y: frame.ball.y),
                                      width: frame.ball.width, joints: pose.joints) { return true }
        let ball = frame.ball
        if frame.player != nil {
            let others = observations.otherPoses(for: frame)
            let wrists = others.flatMap { other -> [PosePoint] in
                guard JugglingContactRules.isHand(ball: .init(x: ball.x, y: ball.y), width: ball.width,
                                                  joints: other.joints) else { return [] }
                return BodySide.allCases.compactMap { side in
                    guard let wrist = other.wrists[side], wrist.confidence >= 0.6,
                          let elbow = other.landmarks[side.elbow], elbow.confidence >= 0.5,
                          hypot((wrist.x-ball.x)/max(ball.width,0.001), (wrist.y-ball.y)/max(ball.height,0.001)) <= 1.5
                    else { return nil }
                    return PosePoint(x: wrist.x, y: wrist.y)
                }
            }
            if !wrists.isEmpty, let hands = observations.hands(for: frame, recordErrors: !isDiagnosing),
               hands.contains(where: { JugglingContactRules.fingersTouchBall(ball: .init(x: ball.x,y: ball.y),
                    width: ball.width,height: ball.height,bodyWrists: wrists,landmarks: $0) }) { return true }
        }
        // The new fallback resolves torso/hand overlap only. Near the legs or
        // head, foreshortening and occlusion remain ambiguous; preserve the
        // original body rule rather than letting hand landmarks veto a kick.
        guard isTorsoHandCandidate(frame) else { return false }
        let wrists = [pose.joints[.leftWrist], pose.joints[.rightWrist]].compactMap { $0 }
        // Fingers can touch the ball beyond the body model's wrist endpoint,
        // even when the torso is closer in the flattened image. Look for actual
        // finger landmarks only when a confident body wrist is already nearby.
        if let cached = handCache[frame.index] { return cached }
        guard let hands = observations.hands(for: frame, recordErrors: !isDiagnosing) else { return false }
        let result = hands.contains { JugglingContactRules.fingersTouchBall(ball: .init(x: ball.x, y: ball.y),
            width: ball.width, height: ball.height, bodyWrists: wrists, landmarks: $0) }
        handCache[frame.index] = result
        return result
    }

    private func isTorsoHandCandidate(_ frame: Frame) -> Bool {
        guard frame.ball.score >= 0.5, let pose = pose(for: frame) else { return false }
        let ball = frame.ball
        guard JugglingContactRules.canResolveTorsoOverlap(ball: .init(x: ball.x, y: ball.y),
            height: ball.height, joints: pose.joints), ball.width > 0, ball.height > 0 else { return false }
        return [pose.joints[.leftWrist], pose.joints[.rightWrist]].compactMap { $0 }.contains {
            hypot(($0.x-ball.x)/ball.width, ($0.y-ball.y)/ball.height) <= 2
        }
    }

    private func pose(for frame: Frame) -> Pose? {
        if let evidencePlayer, frame.player?.id != evidencePlayer.id || !evidencePlayer.canMatchPose { return Pose() }
        let result = observations.pose(for: frame, recordErrors: !isDiagnosing)
        if result == nil, !isDiagnosing, lastError != nil { discardFrames() }
        return result
    }
}
