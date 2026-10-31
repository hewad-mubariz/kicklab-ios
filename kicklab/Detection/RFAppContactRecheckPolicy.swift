import Foundation

/// Shared live/replay contact-image scheduling experiment. Keep tracking retry
/// admission, image budgets, identity checks and counting thresholds unchanged.
nonisolated enum ContactSchedulingPolicy {
    static let signature = "|contact-evidence-scheduling-v3"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--contact-evidence-scheduling")
        #else
        return false
        #endif
    }
}

// Diagnostic admission limits. Rechecks measure a real retained exposure and
// never supply another recheck's identity hint or rewrite trajectory inputs.
nonisolated struct ContactRecheckPolicy {
    var extendsVisibleApproach = false
    var spansContactWindow = false
    var measuresLateApproach = false
    var measuresEarlyRelease = false
    var schedulesContactEvidence = false
    var balancesMissingImpact = false
    static func usesBalancedMissingImpact(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--balanced-missing-impact")
        #else
        return false
        #endif
    }
    static func usesEarlyRelease(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--early-impact-evidence")
        #else
        return false
        #endif
    }
    static func usesLateApproach(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--late-impact-evidence")
        #else
        return false
        #endif
    }
    static let spanSignature = "|contact-evidence-early-release-v3"
    static func usesSpannedWindow(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--contact-evidence-span")
        #else
        return false
        #endif
    }
    // Four 30 Hz exposures, including sub-millisecond capture jitter. A short
    // impact occlusion must not discard the image that the contact verifier
    // can still bracket. Both identity checks and the retained-age cap remain.
    let maximumHintAge = 0.134
    /// Outdoor low kicks can lose the pixel track for 5–8 analyzed exposures.
    /// Keep those actual images eligible for an independent detector check.
    /// The release identity stays within four exposures; buffer and rate caps
    /// are unchanged. A rechecked image can never become another identity hint.
    var maximumApproachHintAge: Double { extendsVisibleApproach ? 0.267 : maximumHintAge }
    let maximumRetainedAge = 0.500
    let maximumRetainedFrames = 8
    let maximumStartLatency = 0.750
    let maximumResultLatency = 0.950
    let minimumInterval = 0.300

    /// A single admitted window can measure its center plus two neighbors.
    /// Every image must retain independent original detections on both sides.
    /// Prefer the closest missing exposures; a smoothed reversal can precede
    /// or follow the actual impact. Never use a repaired view as an identity hint.
    func impactWindow(contactMs: Int, missing: [ContactFrameWindow.Stamp],
                      observed: [ContactFrameWindow.Stamp]) -> [Int] {
        let eligible = missing.filter { frame in
            guard abs(frame.timestampMs-contactMs) <= ((spansContactWindow || measuresLateApproach || measuresEarlyRelease || schedulesContactEvidence || balancesMissingImpact) ? 134 : 67),
                  let before = observed.filter({ $0.timestampMs < frame.timestampMs }).max(by: { $0.timestampMs < $1.timestampMs }),
                  let after = observed.filter({ $0.timestampMs > frame.timestampMs }).min(by: { $0.timestampMs < $1.timestampMs }) else { return false }
            return frame.timestampMs-before.timestampMs <= Int((maximumApproachHintAge*1000).rounded())
                && after.timestampMs-frame.timestampMs <= 134
        }
        let closest = eligible.sorted {
            let a = abs($0.timestampMs-contactMs), b = abs($1.timestampMs-contactMs)
            return a == b ? $0.timestampMs > $1.timestampMs : a < b
        }
        let original = closest.filter { abs($0.timestampMs-contactMs) <= 67 }
        // Keep a real approach about 100 ms before a missing proposal, while
        // preserving coverage around impact. If an original view is just before
        // the proposal, retain the missing release; otherwise retain the missing
        // impact just before it. Replacing the release with a second approach
        // can make a floor rebound look like a later foot contact.
        if balancesMissingImpact,
           let center = original.first(where: { $0.timestampMs == contactMs }),
           let near = original.first(where: { (25...67).contains(contactMs-$0.timestampMs) }),
           let before = observed.filter({ $0.timestampMs < contactMs }).max(by: { $0.timestampMs < $1.timestampMs }),
           let after = observed.filter({ $0.timestampMs > contactMs }).min(by: { $0.timestampMs < $1.timestampMs }),
           (25...67).contains(contactMs-before.timestampMs),
           (25...67).contains(after.timestampMs-contactMs),
           !observed.contains(where: { (68...101).contains(contactMs-$0.timestampMs) }),
           let approach = eligible.filter({ (68...101).contains(contactMs-$0.timestampMs) })
                .min(by: { abs(contactMs-$0.timestampMs-100) < abs(contactMs-$1.timestampMs-100) }) {
            if (25...34).contains(contactMs-before.timestampMs) {
                if let release = original.first(where: { (25...34).contains($0.timestampMs-contactMs) }) {
                    return [center.index, release.index, approach.index]
                }
            } else {
                return [center.index, near.index, approach.index]
            }
        }
        // When the proposal itself is missing at the end of an approach gap,
        // three adjacent images can all be too late to establish approach.
        // Keep the proposal and its nearest approach exposure; substitute an
        // earlier real approach for the remaining redundant neighbor. An
        // original close release still brackets every selected image.
        if schedulesContactEvidence,
           let center = original.first(where: { $0.timestampMs == contactMs }),
           let before = observed.filter({ $0.timestampMs < contactMs }).max(by: { $0.timestampMs < $1.timestampMs }),
           let after = observed.filter({ $0.timestampMs > contactMs }).min(by: { $0.timestampMs < $1.timestampMs }),
           (167...267).contains(contactMs-before.timestampMs), (1...34).contains(after.timestampMs-contactMs),
           let near = original.first(where: { $0.timestampMs < contactMs }),
           let approach = eligible.filter({ (68...100).contains(contactMs-$0.timestampMs) })
                .min(by: { abs(contactMs-$0.timestampMs-100) < abs(contactMs-$1.timestampMs-100) }) {
            return [center.index, near.index, approach.index]
        }
        // An early proposal can spend its third repair on an approach already
        // bracketed by a close original view, leaving the actual impact out.
        // Keep the first two missing release images and use that redundant slot
        // for the next real exposure. Original detections must still establish
        // identity on both sides; the three-job budget and deadlines are unchanged.
        if measuresEarlyRelease, observed.contains(where: { $0.timestampMs == contactMs }),
           let before = observed.filter({ $0.timestampMs < contactMs }).max(by: { $0.timestampMs < $1.timestampMs }),
           let after = observed.filter({ $0.timestampMs > contactMs }).min(by: { $0.timestampMs < $1.timestampMs }),
           (1...67).contains(contactMs-before.timestampMs), (167...267).contains(after.timestampMs-contactMs),
           original.contains(where: { $0.timestampMs < contactMs }),
           let release = eligible.filter({ (68...100).contains($0.timestampMs-contactMs) })
                .min(by: { abs($0.timestampMs-contactMs-100) < abs($1.timestampMs-contactMs-100) }) {
            let retained = Array(original.filter { $0.timestampMs > contactMs }.prefix(2))
            if retained.count == 2 { return (retained + [release]).map(\.index) }
        }
        // A proposal at the first detection after a long approach gap can be
        // later than the physical impact. When the release is already observed
        // one or two exposures later, spend its redundant repair slot on a real
        // approach image. Keep the nearest two views and the same three-job cap.
        if measuresLateApproach, observed.contains(where: { $0.timestampMs == contactMs }),
           let before = observed.filter({ $0.timestampMs < contactMs }).max(by: { $0.timestampMs < $1.timestampMs }),
           let after = observed.filter({ $0.timestampMs > contactMs }).min(by: { $0.timestampMs < $1.timestampMs }),
           (167...267).contains(contactMs-before.timestampMs), (1...67).contains(after.timestampMs-contactMs),
           original.contains(where: { $0.timestampMs > contactMs }),
           let approach = eligible.filter({ (68...100).contains(contactMs-$0.timestampMs) })
                .min(by: { abs(contactMs-$0.timestampMs-100) < abs(contactMs-$1.timestampMs-100) }) {
            let retained = Array(original.filter { $0.timestampMs < contactMs }.prefix(2))
            if retained.count == 2 { return (retained + [approach]).map(\.index) }
        }
        guard spansContactWindow && original.isEmpty else { return Array(original.prefix(3).map(\.index)) }
        // Recover an observed proposal before an occluded impact, followed
        // by a delayed original release. Do not refill an unrelated approach
        // hole when release tracking is already continuous: that can alter
        // the ankle-motion proof for a nearby floor bounce.
        guard observed.contains(where: { $0.timestampMs == contactMs }),
              let release = observed.filter({ $0.timestampMs > contactMs })
                .min(by: { $0.timestampMs < $1.timestampMs }),
              (167...267).contains(release.timestampMs-contactMs) else { return [] }
        return Array(closest.filter { $0.timestampMs > contactMs }.prefix(3)).map(\.index)
    }

    /// Preserve normal ordering while all images have time to run. Only when
    /// the worker budget puts an image at risk of expiring, run oldest first.
    /// Each slot includes a contact inference and an interleaved regular job.
    func executionOrder(_ targets: [Int], missing: [ContactFrameWindow.Stamp],
                        ages: [Int: Double], inferenceBudget: Double) -> [Int] {
        guard schedulesContactEvidence, inferenceBudget.isFinite, inferenceBudget > 0,
              targets.allSatisfy({ ages[$0]?.isFinite == true && ages[$0]! >= 0 }),
              targets.enumerated().contains(where: { slot, target in
                  ages[target]! + Double(2*slot+1)*inferenceBudget > maximumStartLatency
              }) else { return targets }
        let times = Dictionary(missing.map { ($0.index, $0.timestampMs) }, uniquingKeysWith: min)
        return targets.sorted { (times[$0] ?? Int.max) < (times[$1] ?? Int.max) }
    }

    func permitsImpactWindow(source: Double, now: Double, lastSource: Double, lastWall: Double) -> Bool {
        source.isFinite && now.isFinite && source-lastSource >= minimumInterval-0.000001
            && now-lastWall >= minimumInterval-0.000001
    }

    /// Repair a real missing impact neighbor only when that side has no close
    /// observation. Identity must be independently observed before AND after.
    func neighbor(contactMs: Int, missing: [ContactFrameWindow.Stamp], observed: [ContactFrameWindow.Stamp]) -> Int? {
        let candidates = missing.filter { frame in
            let delta = frame.timestampMs-contactMs
            guard delta != 0, abs(delta) <= 100,
                  !observed.contains(where: {
                      let dt = $0.timestampMs-contactMs
                      return delta < 0 ? (-67 ... -1).contains(dt) : (1...67).contains(dt)
                  }),
                  let before = observed.filter({ $0.timestampMs < frame.timestampMs }).max(by: { $0.timestampMs < $1.timestampMs }),
                  let after = observed.filter({ $0.timestampMs > frame.timestampMs }).min(by: { $0.timestampMs < $1.timestampMs }) else { return false }
            return frame.timestampMs-before.timestampMs <= Int((maximumApproachHintAge*1000).rounded())
                && after.timestampMs-frame.timestampMs <= 134
        }
        return candidates.min {
            let a = abs(abs($0.timestampMs-contactMs)-50), b = abs(abs($1.timestampMs-contactMs)-50)
            return a == b ? $0.timestampMs < $1.timestampMs : a < b
        }?.index
    }

    func permits(source: Double, before: Double, after: Double, arrived: Double,
                 now: Double, due: Double, lastSource: Double, lastWall: Double) -> Bool {
        guard [source,before,after,arrived,now,due].allSatisfy(\.isFinite),
              before < source, source < after, after <= arrived,
              source-before <= maximumApproachHintAge+0.000001,
              after-source <= maximumHintAge+0.000001,
              arrived-source <= maximumRetainedAge+0.000001,
              now >= due, now-due <= maximumStartLatency,
              source-lastSource >= minimumInterval-0.000001,
              now-lastWall >= minimumInterval-0.000001 else { return false }
        return true
    }
    func acceptsResult(now: Double, due: Double) -> Bool {
        now.isFinite && due.isFinite && now >= due && now-due <= maximumResultLatency
    }
}

/// One bounded detector retry before the trajectory consumes a lost frame.
/// This measures the current image; it cannot manufacture a kick or bypass gates.
nonisolated struct ImpactGapRecoveryPolicy {
    static func chargesAcceptedRetriesOnly(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("--rf-retry-on-admission")
        #else
        return false
        #endif
    }
    func permits(source: Double, hintTime: Double, now: Double, due: Double,
                 lastSource: Double, lastWall: Double, outstanding: Int, budget: Double) -> Bool {
        [source,hintTime,now,due].allSatisfy(\.isFinite)
            && source > hintTime && source-hintTime <= 0.101
            && source-lastSource >= 0.3 && now-lastWall >= 0.3
            && ContactBacklogPolicy().permits(outstanding: outstanding, currentFrameLag: now-due, rfBudget: budget)
    }
    func accepts(score: Double, completed: Double, due: Double) -> Bool {
        score.isFinite && score >= 0.7 && completed.isFinite && due.isFinite
            && completed >= due && completed-due <= 0.4
    }
}

/// A busy worker has not consumed an inference. Keep the cooldown tied to
/// admitted work, while preserving every age, queue and compute-budget limit.
/// The historical arm is retained for paired device measurements.
nonisolated struct ImpactGapRetrySchedule {
    enum Outcome: Equatable { case ineligible, workerBusy, submitted }
    var chargesAcceptedOnly: Bool
    private var lastSource = -Double.infinity
    private var lastWall = -Double.infinity

    mutating func recordReservedAdmission(source: Double, now: Double) {
        lastSource = source
        lastWall = now
    }

    mutating func attempt(source: Double, hintTime: Double, now: Double, due: Double,
                          outstanding: Int, budget: Double, submit: () -> Bool) -> Outcome {
        guard ImpactGapRecoveryPolicy().permits(source: source, hintTime: hintTime,
            now: now, due: due, lastSource: lastSource, lastWall: lastWall,
            outstanding: outstanding, budget: budget) else { return .ineligible }
        if !chargesAcceptedOnly { lastSource = source; lastWall = now }
        guard submit() else { return .workerBusy }
        lastSource = source
        lastWall = now
        return .submitted
    }
}

/// One reference to the already requested exposure while a busy worker finishes.
/// This is not a new frame choice or another queued inference. The original
/// backlog/start deadline and 400 ms result deadline still apply.
nonisolated struct ImpactGapReservation {
    let index: Int
    let source, due, requestedAt: Double

    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        version(arguments: arguments) > 0
    }

    static func version(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        #if DEBUG
        if arguments.contains("--rf-reserved-gap-v3") { return 3 }
        if arguments.contains("--rf-reserved-gap-v2") { return 2 }
        return arguments.contains("--rf-reserved-gap-v1") ? 1 : 0
        #else
        return 0
        #endif
    }

    static func regularClockAfterAdmission(version: Int, previous: Double, now: Double) -> Double {
        // A newly recovered busy retry must not move every later regular
        // opportunity. Worker occupancy still prevents concurrent inference.
        version >= 2 ? previous : now
    }

    /// A Vision call cannot be preempted. Always allow one due frame, then
    /// yield additional catch-up work after eight ms so capture can ingest.
    static func continuesDrain(version: Int, processed: Int, elapsed: Double) -> Bool {
        version < 3 || processed == 0 || elapsed < 0.008
    }

    func permits(index: Int, source: Double, now: Double, outstanding: Int, budget: Double) -> Bool {
        self.index == index && self.source == source
            && [source,due,requestedAt,now,budget].allSatisfy(\.isFinite)
            && now >= requestedAt && now-requestedAt <= 0.050
            && now+budget <= due+0.400
            && ContactBacklogPolicy().permits(outstanding: outstanding,
                currentFrameLag: now-due, rfBudget: budget)
    }
}

nonisolated enum TrackingDrainBudget {
    static func enabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        return arguments.contains("--rf-drain-budget-v1") || ImpactGapReservation.version(arguments: arguments) >= 3
        #else
        return false
        #endif
    }
}

/// Admit at most one normal frame (queued, running, or unread). Contact work
/// already runs synchronously on the same serial worker, so reserving this slot
/// during a contact inference interleaves fresh tracking between contact views.
/// It never runs two inferences or adds an unbounded work queue.
nonisolated enum RFWorkerAdmissionPolicy {
    static let signature = "|rf-contact-interleave-v1"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--rf-interleave-contact")
        #else
        return false
        #endif
    }
    static func permits(occupied: Bool, contactRequested: Bool, interleaves: Bool, purpose: String) -> Bool {
        !occupied && (!contactRequested || (interleaves && purpose == "regular"))
    }
}

nonisolated enum AdjacentFootEvidencePolicy {
    static let signature = "|adjacent-measured-foot-v3-height"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--adjacent-foot-evidence")
        #else
        return false
        #endif
    }
}
