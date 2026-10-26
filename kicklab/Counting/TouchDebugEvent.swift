import Foundation

/// Observations for the experimental HUD/replay only. These never feed back
/// into acceptance, hand vetoes or numeric trace replay.
nonisolated struct TouchDebugEvent: Codable, Equatable, Sendable {
    let frameIndex: Int
    var time: Double
    let rejection: RejectionReason?
    let handConfirmed: Bool
    let bodyFailure: RestrictedTouchPolicy.Failure?
    let ball: BallObservation?
    var player: ActivePlayerSelection? = nil

    var title: String {
        if rejection == .heldBall { return "Ball held" }
        if handConfirmed { return "Hand touch" }
        return rejection == nil ? "Counted" : "Touch rejected"
    }

    var detail: String {
        if rejection == .disallowedBodyContact, let player, !player.canMatchPose {
            return player.state == .ambiguous ? "Player selection uncertain" : "Selected player not visible"
        }
        switch rejection {
        case .disallowedBodyContact:
            return "Body filter · " + (bodyFailure?.label ?? "Contact area uncertain")
        case .heldBall: return "Handling filter · Sustained grip"
        case .handContact: return "Hand filter · Not counted"
        case .amplitudeTooSmall: return "Ball drop too small"
        case .insufficientImpulse: return "Direction change too weak"
        case .groundBounce: return "Ground filter · Foot contact unconfirmed"
        case .unresolvedLowContact: return "Low contact uncertain · Foot contact unconfirmed"
        case .cooldown: return "Too close to the previous touch"
        case .unsupportedByDetection: return "Ball detection missing near contact"
        case .noPersonRegion: return "Player not detected"
        case .outsidePersonRegion: return "Ball outside player area"
        case .trackLost: return "Ball tracking interrupted"
        case nil: return "Allowed contact · +1"
        }
    }

    func relative(to origin: Double) -> Self {
        var copy = self
        copy.time -= origin
        return copy
    }

    static func visible(in events: [Self], at time: Double) -> Self? {
        events.last { time >= $0.time && time - $0.time < 0.9 }
    }
}

nonisolated extension RestrictedTouchPolicy.Failure {
    var label: String {
        switch self {
        case .missingBall: "Ball missing at contact"
        case .missingPose: "Body pose uncertain"
        case .invalidGeometry: "Body geometry uncertain"
        case .torsoOverlap: "Ball overlaps torso"
        case .outsideAllowedRegions: "Outside head / knee / foot area"
        case .insufficientContactViews: "Not enough views around contact"
        case .handsUncertain: "Hand clearance uncertain; other contact evidence insufficient"
        case .handsNearBall: "Hand or arm too close to ball"
        case .lowContactNeedsFootEvidence: "Low contact needs foot evidence"
        }
    }
}
