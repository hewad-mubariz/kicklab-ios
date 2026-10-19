import Foundation

/// Explicit versions keep live analysis, imports and historical comparisons on
/// the same rules. Historical policies remain available for saved comparisons.
nonisolated struct CountingPolicy: Equatable, Sendable {
    enum BodyContact: String, Sendable {
        case unrestricted, headKneeFoot, clearHandsV2, movingFootV3, poseContinuityV4, observedJointContinuityV5, timedFootMotionV6, observedLegMotionV7, observedLegMotionV8, temporalEvidenceV9, trackedFootV10, observedImpactV11, independentLegV12, legReboundV13, raisedFootV14, footEvidenceV15

        var usesClearHands: Bool { self != .headKneeFoot && self != .unrestricted }
        var usesMovingFoot: Bool { self == .movingFootV3 || usesPoseContinuity }
        var usesPoseContinuity: Bool { self == .poseContinuityV4 || usesObservedJointContinuity }
        var usesObservedJointContinuity: Bool { self == .observedJointContinuityV5 || usesTimedFootMotion }
        var usesTimedFootMotion: Bool { self == .timedFootMotionV6 || self == .observedLegMotionV7 || self == .observedLegMotionV8 || usesTemporalEvidence }
        var usesTemporalEvidence: Bool { self == .temporalEvidenceV9 || self == .trackedFootV10 || usesObservedImpact }
        var usesObservedImpact: Bool { self == .observedImpactV11 || self == .independentLegV12 || self == .legReboundV13 || usesRaisedFoot }
        var usesRaisedFoot: Bool { self == .raisedFootV14 || self == .footEvidenceV15 }
        var bodyTracksFootPixels: Bool { self == .trackedFootV10 }

        /// Arm proximity is not a confirmed hand touch. Strong independent leg
        /// evidence may establish eligibility; hand and holding vetoes still run.
        func allowsObservedLegRecovery(after failure: RestrictedTouchPolicy.Failure?) -> Bool {
            switch self {
            case .observedLegMotionV7: failure == .handsUncertain
            case .observedLegMotionV8: failure == .handsUncertain || failure == .handsNearBall
            case .temporalEvidenceV9, .trackedFootV10, .observedImpactV11: failure == .handsUncertain || failure == .handsNearBall || failure == .invalidGeometry
            // Missing shoulders or sparse arm views must not veto visible leg
            // motion. Keep low-contact/floor eligibility on its existing path.
            case .independentLegV12, .legReboundV13, .raisedFootV14, .footEvidenceV15:
                BodyContact.observedImpactV11.allowsObservedLegRecovery(after: failure)
                    || failure == .missingPose || failure == .insufficientContactViews
            default: false
            }
        }
    }

    enum Handling: String, Sendable { case disabled, sustainedGripV1 }
    var handling: Handling = .disabled

    let verifiesContacts: Bool
    let body: BodyContact
    let ground: GroundContactPolicy

    static var current: Self { configured(arguments: ProcessInfo.processInfo.arguments) }

    static func configured(arguments: [String]) -> Self {
        let body = BodyContact.footEvidenceV15
        return .init(handling: .sustainedGripV1, verifiesContacts: true,
                     body: body, ground: .corroboratedFeet)
    }

    var handlingSignature: String { handling == .disabled ? "" : "|handling-v1" }

    var bodySignature: String {
        switch body {
        case .unrestricted: ""
        case .headKneeFoot: "|head-knee-foot"
        case .clearHandsV2: "|clear-hands-v2"
        case .movingFootV3: "|clear-hands-v3"
        case .poseContinuityV4: "|clear-hands-v4"
        case .observedJointContinuityV5: "|clear-hands-v5"
        case .timedFootMotionV6: "|clear-hands-v6"
        case .observedLegMotionV7: "|observed-leg-v7"
        case .observedLegMotionV8: "|observed-leg-v8"
        case .temporalEvidenceV9: "|temporal-evidence-v9"
        case .trackedFootV10: "|tracked-foot-v10"
        case .observedImpactV11: "|observed-impact-v11"
        case .independentLegV12: "|independent-leg-v12"
        case .legReboundV13: "|leg-rebound-v13"
        case .raisedFootV14: "|raised-foot-v14"
        case .footEvidenceV15: "|foot-evidence-v15"
        }
    }
}
