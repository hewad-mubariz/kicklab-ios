import Foundation
import Testing
@testable import kicklab

struct RaisedFootContactRulesTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Sample: Decodable {
                var ball: BallObservation
                var joints: [BodyJoint: [Double]]
                var evidence: FootPoseSample {
                    .init(pose: .init(timestampMs: ball.timestampMs, ball: .init(x: ball.x, y: ball.y),
                        width: ball.width, height: ball.height, confidence: ball.confidence, imageAspect: 9.0/16,
                        joints: joints.filter { $0.value[2] >= 0.3 }.mapValues { .init(x: $0[0], y: $0[1]) }),
                        ankles: Dictionary(uniqueKeysWithValues: BodySide.allCases.compactMap { side in
                            joints[side.ankle].map { (side, .init(x: $0[0], y: $0[1], confidence: $0[2])) }
                        }))
                }
            }
            let id: String
            let contactMs: Int
            let expectedFoot: Bool
            let samples: [Sample]
        }
        let cases: [Case]
    }
    private final class Resources {}
    private func cases() throws -> [Fixture.Case] {
        try ["raised-foot-contacts", "raised-foot-device-contacts"].flatMap { name in
            let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
        }
    }

    @Test func recoversReviewedInsideFeetWithoutAdmittingHandOrChestWindows() throws {
        let rows = try cases()
        #expect(rows.filter { $0.expectedFoot && !$0.id.hasPrefix("device-") }.map(\.id).sorted() == [
            "inside-foot-100", "inside-foot-455", "inside-foot-499", "inside-foot-567", "inside-foot-722",
            "raised-foot-285", "raised-foot-332", "raised-foot-383"])
        for row in rows {
            #expect(RaisedFootContactRules.confirms(row.samples.map(\.evidence), at: row.contactMs) == row.expectedFoot,
                    "Candidate \(row.id)")
        }
    }

    @Test func bothHandsMustBeVisiblyClearThroughoutTheEvidence() throws {
        for row in try cases() where row.expectedFoot {
            for side in BodySide.allCases {
                for hidden in [true, false] {
                    let samples = row.samples.map { original in
                        var s = original
                        if hidden { s.joints.removeValue(forKey: side.wrist) }
                        else { s.joints[side.wrist] = [s.ball.x, s.ball.y, 1] }
                        return s.evidence
                    }
                    #expect(!RaisedFootContactRules.confirms(samples, at: row.contactMs), "Candidate \(row.id)")
                }
            }
        }
    }

    @Test func weakAnklesRequireAConfidentAnchorAndMultipleViews() throws {
        for row in try cases() where row.expectedFoot {
            let weak = row.samples.map { original in
                var s = original
                for side in BodySide.allCases {
                    if var ankle = s.joints[side.ankle] {
                        ankle[2] = min(ankle[2], 0.29); s.joints[side.ankle] = ankle
                    }
                }
                return s.evidence
            }
            #expect(!RaisedFootContactRules.confirms(weak, at: row.contactMs))
            for sample in row.samples.map(\.evidence) {
                #expect(!RaisedFootContactRules.confirms([sample], at: row.contactMs))
            }
            #expect(!RaisedFootContactRules.confirms(row.samples.map(\.evidence), at: row.contactMs+500))
        }
    }

    @Test func aStationaryRaisedFootOrWholeBodyShiftCannotSupplyAKick() throws {
        for row in try cases() where row.expectedFoot {
            let offsets = BodySide.allCases.reduce(into: [BodySide: [Double]]()) { result, side in
                if let sample = row.samples.first(where: {
                    ($0.joints[side.ankle]?[2] ?? 0) >= 0.3 && ($0.joints[side.hip]?[2] ?? 0) >= 0.3
                }), let ankle = sample.joints[side.ankle], let hip = sample.joints[side.hip] {
                    result[side] = [ankle[0]-hip[0], ankle[1]-hip[1]]
                }
            }
            let stationary = row.samples.map { original in
                var s = original
                for side in BodySide.allCases {
                    if let offset = offsets[side], let hip = s.joints[side.hip] {
                        s.joints[side.ankle] = [hip[0]+offset[0], hip[1]+offset[1], 0.9]
                    } else { s.joints.removeValue(forKey: side.ankle) }
                }
                return s.evidence
            }
            #expect(!RaisedFootContactRules.confirms(stationary, at: row.contactMs), "Candidate \(row.id)")
        }
    }

    @Test func occludedImpactRequiresObservedAnklesOnBothSidesOfTheGap() throws {
        let row = try #require(cases().first { $0.id == "device-latest-285" })
        let removed = row.samples.map { original in
            var s = original
            if s.ball.timestampMs >= row.contactMs {
                s.joints.removeValue(forKey: .leftAnkle)
                s.joints.removeValue(forKey: .rightAnkle)
            }
            return s.evidence
        }
        #expect(!RaisedFootContactRules.confirms(removed, at: row.contactMs), "Never extrapolate a hidden foot from its approach alone")
    }

    @Test func raisingTheBallToTheChestCannotUseTheFootException() throws {
        for row in try cases() where row.expectedFoot {
            let upperBody = row.samples.map { original in
                var s = original
                s.ball.y -= 0.3
                // Keep the apparent ball/ankle proximity, so a moving nearby
                // ankle cannot turn an upper-torso reversal into a foot touch.
                for side in BodySide.allCases {
                    if var ankle = s.joints[side.ankle] {
                        ankle[1] -= 0.3; s.joints[side.ankle] = ankle
                    }
                }
                return s.evidence
            }
            #expect(!RaisedFootContactRules.confirms(upperBody, at: row.contactMs), "Candidate \(row.id)")
        }
    }
}
