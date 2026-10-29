import Foundation

/// Explicit versions keep live analysis, imports and historical comparisons on
/// the same rules. Historical policies remain available for saved comparisons.
nonisolated struct CountingPolicy: Equatable, Sendable {
    enum BodyContact: String, Sendable {
        case unrestricted, headKneeFoot, clearHandsV2, movingFootV3, poseContinuityV4, observedJointContinuityV5, timedFootMotionV6, observedLegMotionV7, observedLegMotionV8, temporalEvidenceV9, trackedFootV10, observedImpactV11, independentLegV12, legReboundV13, raisedFootV14, footEvidenceV15, contactEvidenceV16, impactWindowV17, floorEvidenceV18, floorRescueV19, toeContactV20, visibleFootV21, measuredFootV22, smallArcV23

        var usesClearHands: Bool { self != .headKneeFoot && self != .unrestricted }
        var usesMovingFoot: Bool { self == .movingFootV3 || usesPoseContinuity }
        var usesPoseContinuity: Bool { self == .poseContinuityV4 || usesObservedJointContinuity }
        var usesObservedJointContinuity: Bool { self == .observedJointContinuityV5 || usesTimedFootMotion }
        var usesTimedFootMotion: Bool { self == .timedFootMotionV6 || self == .observedLegMotionV7 || self == .observedLegMotionV8 || usesTemporalEvidence }
        var usesTemporalEvidence: Bool { self == .temporalEvidenceV9 || self == .trackedFootV10 || usesObservedImpact }
        var usesObservedImpact: Bool { self == .observedImpactV11 || self == .independentLegV12 || self == .legReboundV13 || usesRaisedFoot }
        var usesContactEvidence: Bool { self == .contactEvidenceV16 || usesImpactWindow }
        var usesImpactWindow: Bool { self == .impactWindowV17 || usesFloorEvidence }
        var usesMeasuredFoot: Bool { self == .measuredFootV22 || self == .smallArcV23 }
        var usesVisibleFoot: Bool { self == .visibleFootV21 || usesMeasuredFoot }
        var usesToeContact: Bool { self == .toeContactV20 || usesVisibleFoot }
        var usesFloorEvidence: Bool { self == .floorEvidenceV18 || self == .floorRescueV19 || usesToeContact }
        var usesRaisedFoot: Bool { self == .raisedFootV14 || self == .footEvidenceV15 || usesContactEvidence }
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
            case .independentLegV12, .legReboundV13, .raisedFootV14, .footEvidenceV15, .contactEvidenceV16, .impactWindowV17, .floorEvidenceV18, .floorRescueV19, .toeContactV20, .visibleFootV21, .measuredFootV22, .smallArcV23:
                BodyContact.observedImpactV11.allowsObservedLegRecovery(after: failure)
                    || failure == .missingPose || failure == .insufficientContactViews
            default: false
            }
        }
    }

    enum Handling: String, Sendable { case disabled, sustainedGripV1, temporalGripV2 }
    var handling: Handling = .disabled

    let verifiesContacts: Bool
    let body: BodyContact
    let ground: GroundContactPolicy

    static var current: Self { configured(arguments: TouchCountingDebugProfile.arguments) }

    static func configured(arguments: [String]) -> Self {
        #if DEBUG || TOUCH_COUNTER_BETA
        if arguments.contains("--small-arc-v23") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .smallArcV23, ground: .corroboratedFeet)
        }
        #endif
        #if DEBUG
        if arguments.contains("--measured-foot-v22") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .measuredFootV22, ground: .corroboratedFeet)
        }
        if arguments.contains("--visible-foot-v21") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .visibleFootV21, ground: .corroboratedFeet)
        }
        if arguments.contains("--toe-contact-v20") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .toeContactV20, ground: .corroboratedFeet)
        }
        if arguments.contains("--floor-rescue-v19") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .floorRescueV19, ground: .corroboratedFeet)
        }
        if arguments.contains("--floor-evidence-v18") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .floorEvidenceV18, ground: .corroboratedFeet)
        }
        if arguments.contains("--impact-window-v17") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .impactWindowV17, ground: .corroboratedFeet)
        }
        if arguments.contains("--contact-evidence-v16") {
            return .init(handling: .temporalGripV2, verifiesContacts: true,
                         body: .contactEvidenceV16, ground: .corroboratedFeet)
        }
        if arguments.contains("--foot-evidence-v15") {
            return .init(handling: .sustainedGripV1, verifiesContacts: true,
                         body: .footEvidenceV15, ground: .corroboratedFeet)
        }
        #endif
        return .init(handling: .temporalGripV2, verifiesContacts: true,
                     body: .visibleFootV21, ground: .corroboratedFeet)
    }

    var handlingSignature: String {
        switch handling {
        case .disabled: ""
        case .sustainedGripV1: "|handling-v1"
        case .temporalGripV2: "|handling-v2"
        }
    }

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
        case .contactEvidenceV16: "|contact-evidence-v16"
        case .impactWindowV17: "|impact-window-v17"
        case .floorEvidenceV18: "|floor-evidence-v18"
        case .floorRescueV19: "|floor-rescue-v19"
        case .toeContactV20: "|toe-contact-v20"
        case .visibleFootV21: "|visible-foot-v21"
        case .measuredFootV22: "|measured-foot-v22"
        case .smallArcV23: "|small-arc-v23"
        }
    }
}

/// A weak ankle cannot establish a below-ankle kick without resolved evidence.
nonisolated enum WeakLowFootPolicy {
    static let signature = "|weak-low-foot-v1"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--weak-low-foot-proof")
        #else
        return false
        #endif
    }
}

/// Independent debug arms for real-evidence recovery; release selection is unchanged.
nonisolated enum MeasuredReboundPolicy {
    static func raisedForefoot(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--raised-forefoot-proof")
        #else
        return false
        #endif
    }
    static func settledProbe(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--settled-rebound-probe")
        #else
        return false
        #endif
    }
    static func confirmation(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--measured-rebound-confirmation")
        #else
        return false
        #endif
    }
    static func slowRise(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--slow-measured-rise")
        #else
        return false
        #endif
    }
    static func raisedFoot(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--raised-compact-foot")
        #else
        return false
        #endif
    }
}

/// Independent debug arms; release selection and old serialized traces stay unchanged.
nonisolated enum ObservedContactRecoveryPolicy {
    static func alignedLeg(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--aligned-leg-ground")
        #else
        return false
        #endif
    }
    static func gapRebound(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--measured-gap-candidate")
        #else
        return false
        #endif
    }
    static func terminalRebound(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--terminal-rebound-evidence")
        #else
        return false
        #endif
    }
}

/// Isolated ground-proof correction; normal release selection is unchanged.
nonisolated enum GroundImpactEvidencePolicy {
    static let signature = "|planted-impact-evidence-v1"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--ground-impact-evidence")
        #else
        return false
        #endif
    }
}

/// Numeric evidence only; no extra detector work or release default change.
nonisolated enum UnliftedFloorReboundPolicy {
    static let signature = "|unlifted-floor-rebound-v1"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--unlifted-floor-rebound")
        #else
        return false
        #endif
    }
}

/// A bounded measured contact may establish region eligibility at its real time.
nonisolated enum AlignedFootRegionPolicy {
    static let signature = "|aligned-foot-region-v1"
    static func enabled(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--aligned-foot-region")
        #else
        return false
        #endif
    }
}

nonisolated enum MeasuredFootImpactPolicy {
    static func corroboratedFloor(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--corroborated-floor-rebound")
        #else
        return false
        #endif
    }
    static func weakSupport(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--corroborated-support-ankle")
        #else
        return false
        #endif
    }
    static func toeLift(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--brief-toe-lift")
        #else
        return false
        #endif
    }
    static func floorRebound(arguments: [String] = TouchCountingDebugProfile.arguments) -> Bool {
        #if DEBUG || TOUCH_COUNTER_BETA
        return arguments.contains("--descending-floor-rebound")
        #else
        return false
        #endif
    }
}
