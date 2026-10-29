import Foundation

/// A smoothed reversal may lead the observed foot impact by one or two
/// exposures. Reuse the existing positive foot proof at a real nearby impact;
/// no interpolated ball, inferred joint, or looser contact threshold is used.
nonisolated enum AdjacentFootContactRules {
    static func measuredEvidence(_ input: [FootContactRules.Sample], proposedMs: Int) -> FootContactEvidence? {
        let samples = input.sorted { $0.timestampMs < $1.timestampMs }
        guard samples.count <= 24, Set(samples.map(\.timestampMs)).count == samples.count else { return nil }
        let impacts = samples.filter { abs($0.timestampMs-proposedMs) <= 67 }.sorted {
            let a = abs($0.timestampMs-proposedMs), b = abs($1.timestampMs-proposedMs)
            return a == b ? $0.timestampMs < $1.timestampMs : a < b
        }
        func visible(_ s: FootContactRules.Sample) -> Bool {
            [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                && s.width > 0 && s.height > 0 && s.confidence >= 0.5
                && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
        }
        for impact in impacts where visible(impact) {
            for before in samples where (40...134).contains(impact.timestampMs-before.timestampMs) && visible(before) {
                for after in samples where (40...134).contains(after.timestampMs-impact.timestampMs) && visible(after) {
                    guard confirmsElevatedImpact(before: before, contact: impact, after: after) else { continue }
                    var evidence = FootContactEvidence(before: before, contact: impact, after: after)
                    evidence.proposedContactMs = proposedMs
                    evidence.usesFourExposureWindow = true
                    return evidence
                }
            }
        }
        return nil
    }

    /// Searching neighboring exposures must not borrow a grass rebound next
    /// to a moving foot. The SAME ankle that supplies the approach/release
    /// proof must also place the ball center at ankle height or above, allowing
    /// a fifth of a diameter for localization error. Ordinary proofs stay intact.
    private static func confirmsElevatedImpact(before: FootContactRules.Sample,
        contact: FootContactRules.Sample, after: FootContactRules.Sample) -> Bool {
        for side in BodySide.allCases {
            guard let ankle = contact.ankles[side], ankle.confidence >= 0.3,
                  contact.ballY <= ankle.y + 0.2 * contact.height else { continue }
            func onlySide(_ sample: FootContactRules.Sample) -> FootContactRules.Sample {
                return .init(timestampMs: sample.timestampMs, ballX: sample.ballX, ballY: sample.ballY,
                    width: sample.width, height: sample.height, confidence: sample.confidence,
                    ankles: sample.ankles.filter { $0.key == side }, hips: sample.hips.filter { $0.key == side })
            }
            if FootContactRules.confirms(before: onlySide(before), contact: onlySide(contact), after: onlySide(after),
                usesFourExposureWindow: true) { return true }
        }
        return false
    }

    /// Replay compatibility for earlier diagnostic traces. New live evidence
    /// uses measuredEvidence and its additional same-foot height guard.
    static func contactTime(_ input: [FootContactRules.Sample], at proposedMs: Int) -> Int? {
        let samples = input.sorted { $0.timestampMs < $1.timestampMs }
        guard samples.contains(where: { $0.timestampMs == proposedMs }),
              Set(samples.map(\.timestampMs)).count == samples.count else { return nil }
        func visible(_ s: FootContactRules.Sample) -> Bool {
            [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                && s.width > 0 && s.height > 0 && s.confidence >= 0.5
                && s.ballX-s.width/2 >= 0 && s.ballX+s.width/2 <= 1
                && s.ballY-s.height/2 >= 0 && s.ballY+s.height/2 <= 1
        }
        for impact in samples where (25...67).contains(impact.timestampMs-proposedMs) && visible(impact) {
            // Four 30 Hz exposures take 133.3 ms. Preserve their real clock;
            // rounding it down to 130 discards an otherwise valid approach.
            for before in samples where (40...134).contains(impact.timestampMs-before.timestampMs) && visible(before) {
                for after in samples where (40...134).contains(after.timestampMs-impact.timestampMs) && visible(after) {
                    if FootContactRules.confirms(before: before, contact: impact, after: after,
                        usesFourExposureWindow: true) {
                        return impact.timestampMs
                    }
                }
            }
        }
        return nil
    }
}
