import Foundation

nonisolated enum ContactReviewReason: String, Codable, Sendable {
    case handContact, heldBall, groundContact
    case lowContactUncertain, handsUncertain, bodyUncertain, playerUncertain, ballUncertain, continuityGap
}

/// Small, production evidence collected after a counter decision. No pixels,
/// extra inference or feedback into counting; independent of the bounded debug trace.
nonisolated struct TouchReviewEvidence: Sendable {
    struct Observation: Sendable {
        let time: Double
        let kind: ContactReviewReason
    }
    private(set) var observations: [Observation] = []
    private(set) var complete = true
    private let limit: Int
    init(limit: Int = 4_096) { self.limit = max(1, limit) }

    func relative(to origin: Double) -> Self {
        var result = self
        result.observations = observations.map { .init(time: $0.time - origin, kind: $0.kind) }
        return result
    }

    mutating func append(_ event: TouchDebugEvent, groundConfirmed: Bool = false) {
        guard event.time.isFinite, let rejection = event.rejection else { return }
        let kind: ContactReviewReason
        switch rejection {
        case .cooldown, .amplitudeTooSmall, .insufficientImpulse: return
        case .heldBall: kind = .heldBall
        case .handContact: kind = .handContact
        case .groundBounce: kind = groundConfirmed ? .groundContact : .lowContactUncertain
        case .unresolvedLowContact: kind = .lowContactUncertain
        case .noPersonRegion, .outsidePersonRegion: kind = .playerUncertain
        case .unsupportedByDetection, .trackLost: kind = .ballUncertain
        case .disallowedBodyContact:
            if event.handConfirmed { kind = .handContact }
            else if event.player?.canMatchPose == false { kind = .playerUncertain }
            else if [.handsUncertain, .handsNearBall].contains(event.bodyFailure) { kind = .handsUncertain }
            else if event.bodyFailure == .missingBall { kind = .ballUncertain }
            else if event.bodyFailure == .lowContactNeedsFootEvidence { kind = .lowContactUncertain }
            else { kind = .bodyUncertain }
        }
        guard observations.count < limit else { complete = false; return }
        observations.append(.init(time: event.time, kind: kind))
    }
}
