import Foundation
import Testing
@testable import kicklab

struct RaisedKneeContactRulesTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Sample: Decodable {
                let timestampMs: Int
                let ball: BallObservation
                let joints: [BodyJoint: [Double]]
                var evidence: ContactPoseSample {
                    .init(timestampMs: timestampMs, ball: .init(x: ball.x, y: ball.y),
                        width: ball.width, height: ball.height, confidence: ball.confidence, imageAspect: 9.0/16,
                        joints: joints.filter { $0.value[2] >= 0.3 }.mapValues { .init(x: $0[0], y: $0[1]) })
                }
            }
            let contactMs: Int
            let expectedKnee: Bool
            let samples: [Sample]
        }
        let cases: [Case]
    }
    private final class Resources {}
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "raised-knee-contacts", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func recoversSixReviewedKneesWithoutAcceptingOtherRejectedCandidates() throws {
        let cases = try fixture().cases
        #expect(cases.filter(\.expectedKnee).count == 6)
        for row in cases {
            #expect(RaisedKneeContactRules.confirms(row.samples.map(\.evidence), at: row.contactMs) == row.expectedKnee,
                    "Candidate at \(row.contactMs) ms")
        }
    }

    @Test func cannotRecoverFromOneViewOrAWindowFarFromTheContact() throws {
        for row in try fixture().cases where row.expectedKnee {
            let samples = row.samples.map(\.evidence)
            for sample in samples { #expect(!RaisedKneeContactRules.confirms([sample], at: row.contactMs)) }
            #expect(!RaisedKneeContactRules.confirms(samples, at: row.contactMs+500))
        }
    }

    @Test func missingOrBallOverlappingWristsKeepRaisedKneesAmbiguous() throws {
        for row in try fixture().cases where row.expectedKnee {
            for side in BodySide.allCases {
                for hidden in [true, false] {
                    let changed = row.samples.map { raw in
                        let s = raw.evidence
                        var joints = s.joints
                        if hidden { joints.removeValue(forKey: side.wrist) }
                        else { joints[side.wrist] = s.ball }
                        return ContactPoseSample(timestampMs: s.timestampMs, ball: s.ball,
                            width: s.width, height: s.height, confidence: s.confidence,
                            imageAspect: s.imageAspect, joints: joints)
                    }
                    #expect(!RaisedKneeContactRules.confirms(changed, at: row.contactMs))
                }
            }
        }
    }

    @Test func aHeldRaisedKneeDoesNotSupplyContactMotion() throws {
        for row in try fixture().cases where row.expectedKnee {
            for sample in row.samples.map(\.evidence) {
                let samePose = [0, 33, 66].map { offset in
                    ContactPoseSample(timestampMs: row.contactMs+offset, ball: sample.ball,
                        width: sample.width, height: sample.height, confidence: sample.confidence,
                        imageAspect: sample.imageAspect, joints: sample.joints)
                }
                #expect(!RaisedKneeContactRules.confirms(samePose, at: row.contactMs))
            }
        }
    }
}
