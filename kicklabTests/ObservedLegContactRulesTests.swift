import Foundation
import Testing
@testable import kicklab

struct ObservedLegContactRulesTests {
    private final class Resources {}
    private struct Row: Decodable {
        struct View: Decodable {
            var timestampMs: Int
            var ball: [Double]
            var joints: [BodyJoint: [Double]]
            var landmarks: [BodyJoint: [Double]]
            var ankles: [BodySide: [Double]]
            var sample: FootPoseSample {
                .init(pose: .init(timestampMs: timestampMs,ball: .init(x:ball[0],y:ball[1]),
                    width:ball[2],height:ball[3],confidence:ball[4],imageAspect:ball[5],
                    joints:joints.mapValues { .init(x:$0[0],y:$0[1]) }),
                    ankles:ankles.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) },
                    landmarks:landmarks.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) })
            }
        }
        let id, contact: String
        let contactMs: Int
        let samples: [View]
    }
    private func rows(resource: String = "observed-leg-device-contacts") throws -> [Row] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: resource,withExtension: "json"))
        return try JSONDecoder().decode([Row].self,from: Data(contentsOf:url))
    }

    @Test func temporalEvidenceRecoversThreeReviewedContactsWithoutAlteringObservations() throws {
        for row in try rows(resource:"temporal-evidence-device-contacts") {
            let samples = row.samples.map(\.sample)
            let expected = [7648,11857].contains(row.contactMs) ? row.contactMs
                : row.contactMs == 14595 ? 14595 : nil
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs,usesTemporalEvidence:true) == expected)
            let supported = TemporalContactEvidence.corroborateWrists(samples)
            #expect((ClearHandsContactRules.failure(supported.map(\.pose),at:row.contactMs) == nil) == (row.contactMs == 10921))
            for (original,corroborated) in zip(samples,supported) {
                #expect(original.landmarks == corroborated.landmarks)
                #expect(original.pose.confidence == corroborated.pose.confidence)
                for side in BodySide.allCases {
                    if original.pose.joints[side.wrist] == nil, let wrist = corroborated.pose.joints[side.wrist] {
                        #expect(wrist.x == original.landmarks[side.wrist]?.x)
                        #expect(wrist.y == original.landmarks[side.wrist]?.y)
                    }
                }
            }
        }
    }

    @Test(arguments:["absent", "jump", "weakThroughout", "stale", "handAtBall"])
    func wristTrackCannotHideMissingJumpingOrNearbyHand(change: String) throws {
        let row = try #require(try rows(resource:"temporal-evidence-device-contacts").first { $0.contactMs == 10921 })
        let samples = row.samples.map { original in
            var s = original
            if change == "stale" { s.timestampMs = row.contactMs+(s.timestampMs-row.contactMs)*3 }
            if var wrist = s.landmarks[.rightWrist] {
                if change == "weakThroughout" { wrist[2] = 0.2 }
                if s.timestampMs == row.contactMs {
                    if change == "absent" { wrist = [0,0,0] }
                    if change == "jump" { wrist[0] += 0.25 }
                    if change == "handAtBall" { wrist = [s.ball[0],s.ball[1],0.2] }
                }
                s.landmarks[.rightWrist] = wrist
                if wrist[2] < 0.3 { s.joints.removeValue(forKey:.rightWrist) }
            }
            return s.sample
        }
        #expect(ClearHandsContactRules.failure(TemporalContactEvidence.corroborateWrists(samples).map(\.pose),at:row.contactMs) != nil)
    }

    @Test(arguments:["central", "veryWeak", "weakNeighbor", "secondWeak", "jump", "sizeJump", "stale"])
    func marginalBallNeedsStrongAdjacentConsistentEdgeObservations(change: String) throws {
        let row = try #require(try rows(resource:"temporal-evidence-device-contacts").first { $0.contactMs == 7648 })
        let samples = row.samples.map { original in
            var s = original
            if change == "central" { s.ball[0] += 0.35 }
            if change == "stale" { s.timestampMs = row.contactMs+(s.timestampMs-row.contactMs)*3 }
            if s.timestampMs == row.contactMs {
                if change == "veryWeak" { s.ball[4] = 0.39 }
                if change == "jump" { s.ball[1] += 0.3 }
                if change == "sizeJump" { s.ball[3] *= 2 }
            }
            if original.timestampMs == 7682 {
                if change == "weakNeighbor" { s.ball[4] = 0.74 }
                if change == "secondWeak" { s.ball[4] = 0.45 }
            }
            return s.sample
        }
        #expect(!TemporalContactEvidence.supportsBallTrack(samples.map(\.pose)))
        #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs,usesTemporalEvidence:true) == nil)
    }

    @Test func singleHipReferenceStillNeedsAStableConfidentSupportingFoot() throws {
        let row = try #require(try rows(resource:"temporal-evidence-device-contacts").first { $0.contactMs == 11857 })
        for change in ["missingHip", "weakSupport", "movingSupport", "missingLeg"] {
            let samples = row.samples.map { original in
                var s = original
                if change == "missingHip" { s.landmarks.removeValue(forKey:.leftHip) }
                if change == "missingLeg" { s.landmarks.removeValue(forKey:.leftAnkle) }
                if var support = s.landmarks[.rightAnkle] {
                    if change == "weakSupport" { support[2] = 0.49 }
                    if change == "movingSupport" { support[1] += Double(s.timestampMs-row.contactMs)/1000 }
                    s.landmarks[.rightAnkle] = support
                }
                return s.sample
            }
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs,usesTemporalEvidence:true) == nil)
        }
    }

    @Test func observedFootContactCanResolveProjectedArmProximity() throws {
        // Source-reviewed kick at 14.59 s in eighteen.mov. The same unmodified
        // device landmarks pass leg evidence while arm clearance is ambiguous.
        let fixture = try rows(resource: "leg-routing-device-contact")
        let row = try #require(fixture.first)
        let samples = row.samples.map(\.sample)
        let failure = ClearHandsContactRules.failure(samples.map(\.pose),at:row.contactMs)
        #expect(failure == .handsNearBall)
        #expect(MovingFootContactRules.contactTime(ContactPoseContinuity.corroborate(samples),
            at:row.contactMs,allowsLiftedFoot:true) == nil)
        #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs) == 14595)
        #expect(!CountingPolicy.BodyContact.observedLegMotionV7.allowsObservedLegRecovery(after:failure))
        #expect(CountingPolicy.BodyContact.observedLegMotionV8.allowsObservedLegRecovery(after:failure))

        let absentLegs = samples.map { original in
            var sample = original; sample.landmarks = [:]; return sample
        }
        #expect(ObservedLegContactRules.contactTime(absentLegs,at:row.contactMs) == nil)
    }

    @Test func legRecoveryDoesNotRelaxMissingGeometryOrGroundEligibility() {
        let policy = CountingPolicy.BodyContact.observedLegMotionV8
        let failures: [RestrictedTouchPolicy.Failure?] = [nil, .missingBall, .missingPose,
            .invalidGeometry, .insufficientContactViews, .lowContactNeedsFootEvidence,
            .torsoOverlap, .outsideAllowedRegions]
        for failure in failures {
            #expect(!policy.allowsObservedLegRecovery(after:failure))
        }
        #expect(policy.allowsObservedLegRecovery(after:.handsUncertain))
    }

    @Test func observedMotionRecoversEightCleanFeetAndOneKneeWithUncertainArms() throws {
        // Passport juggling_5 and juggling_6: nine source-reviewed misses.
        // SHA-256 and pre-output visual labels live in the Passport manifest.
        let rows = try rows()
        #expect(rows.count == 9)
        #expect(rows.filter { $0.contact == "knee" }.count == 1)
        for row in rows {
            let samples = row.samples.map(\.sample)
            #expect(ClearHandsContactRules.failure(samples.map(\.pose),at:row.contactMs) == .handsUncertain)
            #expect(MovingFootContactRules.contactTime(ContactPoseContinuity.corroborate(samples),
                at:row.contactMs,allowsLiftedFoot:true) == nil)
            let time = try #require(ObservedLegContactRules.contactTime(samples,at:row.contactMs),"\(row.id)")
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs,usesTemporalEvidence:true) == time,
                "Preserve the observed impact time used by the aligned hand veto")
            #expect((0...100).contains(time-row.contactMs))
            #expect(samples.contains { $0.pose.timestampMs == time })
        }
    }

    @Test func missingUpperBodyCannotBlockIndependentObservedLegEvidence() throws {
        // Unmodified phone observations with missing shoulders but usable legs.
        // These contacts already counted through other paths; this checks that
        // leg eligibility itself no longer depends on the arm failure category.
        let fixture = try rows(resource: "independent-leg-device-contacts")
        #expect(fixture.count == 2)
        for row in fixture {
            let samples = row.samples.map(\.sample)
            let failure = ClearHandsContactRules.failure(samples.map(\.pose), at: row.contactMs)
            #expect(failure == .missingPose)
            #expect(!CountingPolicy.BodyContact.observedImpactV11.allowsObservedLegRecovery(after: failure))
            #expect(CountingPolicy.current.body.allowsObservedLegRecovery(after: failure))
            #expect(ObservedLegContactRules.contactTime(samples, at: row.contactMs,
                usesTemporalEvidence: CountingPolicy.current.body.usesTemporalEvidence) == row.contactMs)
        }
    }

    @Test func independentLegEligibilityDoesNotRequireVisibleArms() throws {
        for row in try rows() {
            let original = row.samples.map(\.sample)
            let expected = try #require(ObservedLegContactRules.contactTime(original, at: row.contactMs,
                usesTemporalEvidence: true))
            let samples = row.samples.map { view in
                var s = view
                for side in BodySide.allCases {
                    for name in [side.shoulder, side.elbow, side.wrist] {
                        s.joints.removeValue(forKey: name)
                        s.landmarks.removeValue(forKey: name)
                    }
                }
                return s.sample
            }
            let failure = ClearHandsContactRules.failure(samples.map(\.pose), at: row.contactMs)
            #expect(failure == .missingPose)
            #expect(CountingPolicy.current.body.allowsObservedLegRecovery(after: failure))
            #expect(ObservedLegContactRules.contactTime(samples, at: row.contactMs,
                usesTemporalEvidence: true) == expected)
        }
    }

    @Test func sparseArmViewsCannotBlockObservedFootMotion() throws {
        let row = try #require(try rows().first { $0.id == "juggling_5-5" })
        // Keep three actual observations 100 ms apart, without interpolation.
        // Too sparse for chest clearance, but enough for the stricter leg path.
        let samples = row.samples.filter { [row.contactMs-100, row.contactMs, row.contactMs+100].contains($0.timestampMs) }
            .map(\.sample)
        #expect(samples.count == 3)
        let failure = ClearHandsContactRules.failure(samples.map(\.pose), at: row.contactMs)
        #expect(failure == .insufficientContactViews)
        #expect(!CountingPolicy.BodyContact.observedImpactV11.allowsObservedLegRecovery(after: failure))
        #expect(CountingPolicy.current.body.allowsObservedLegRecovery(after: failure))
        #expect(ObservedLegContactRules.contactTime(samples, at: row.contactMs,
            usesTemporalEvidence: true) == row.contactMs)
    }

    @Test(arguments: ["missingPose", "weakPose", "stationaryLegs", "floorHeight", "noBallReversal"])
    func missingOrContradictoryEvidenceCannotRecoverContact(change: String) throws {
        for row in try rows() {
            let impact = try #require(row.samples.first { $0.timestampMs == row.contactMs })
            let samples = row.samples.map { original in
                var s = original
                if change == "missingPose" { s.landmarks = [:] }
                if change == "weakPose" { s.landmarks = s.landmarks.mapValues { [$0[0],$0[1],0.29] } }
                if change == "stationaryLegs" {
                    for side in BodySide.allCases {
                        for joint in [side.knee,side.ankle] {
                            if let anchor = impact.landmarks[side.hip], let point = impact.landmarks[joint],
                               let hip = s.landmarks[side.hip] {
                                s.landmarks[joint] = [hip[0]+point[0]-anchor[0],hip[1]+point[1]-anchor[1],0.9]
                            } else { s.landmarks.removeValue(forKey:joint) }
                        }
                    }
                }
                if change == "floorHeight" { s.ball[1] = 0.95 }
                if change == "noBallReversal" {
                    // Flat relative to each hip would require both hips to
                    // agree; hold the complete observed body still as well.
                    s.landmarks = impact.landmarks
                    s.ball = impact.ball
                }
                return s.sample
            }
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs) == nil,"\(row.id): \(change)")
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs,
                usesTemporalEvidence: CountingPolicy.current.body.usesTemporalEvidence) == nil,"\(row.id): \(change)")
        }
    }

    @Test func supportMustBeConfident() throws {
        for row in try rows() {
            for confidence in [0.0,0.49] {
                let samples = row.samples.map { original in
                    var s = original
                    for side in BodySide.allCases {
                        if var p = s.landmarks[side.ankle] { p[2] = confidence; s.landmarks[side.ankle] = p }
                    }
                    return s.sample
                }
                #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs) == nil,"\(row.id)")
            }
        }
    }

    @Test func movingSupportCannotEstablishFloorClearance() throws {
        for row in try rows() {
            // The left ankle supports the right-foot/right-knee cases, and
            // vice versa. Alter only that reference, leaving the kick intact.
            let active: BodySide = ["juggling_5-5", "juggling_5-128", "juggling_5-252"].contains(row.id) ? .left : .right
            let samples = row.samples.map { original in
                var s = original
                if var ankle = s.landmarks[active.opposite.ankle] {
                    ankle[1] += Double(s.timestampMs-row.contactMs)/1000
                    s.landmarks[active.opposite.ankle] = ankle
                }
                return s.sample
            }
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs) == nil,"\(row.id)")
        }
    }

    @Test func bodyAndCameraTranslationAloneCannotCreateContact() throws {
        for row in try rows() {
            let reference = row.samples[0]
            let samples = row.samples.enumerated().map { index, original in
                var s = original
                let shift = Double(index)*0.003
                s.landmarks = reference.landmarks.mapValues { [$0[0],$0[1]+shift,$0[2]] }
                s.ball = reference.ball; s.ball[1] += shift
                return s.sample
            }
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs) == nil,"\(row.id)")
        }
    }

    @Test func duplicateStaleAndMissingImpactViewsDoNotCount() throws {
        for row in try rows() {
            let samples = row.samples.map(\.sample)
            #expect(ObservedLegContactRules.contactTime(samples,at:row.contactMs+500) == nil)
            #expect(ObservedLegContactRules.contactTime(samples.filter { $0.pose.timestampMs != row.contactMs },at:row.contactMs) == nil)
            #expect(ObservedLegContactRules.contactTime([samples[0],samples[0],samples[0]],at:row.contactMs) == nil)
        }
    }
}
