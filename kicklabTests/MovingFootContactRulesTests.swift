import Foundation
import Testing
@testable import kicklab

struct MovingFootContactRulesTests {
    private final class Resources {}
    private struct Row: Decodable {
        struct View: Decodable {
            var timestampMs: Int
            var ball: [Double]
            var joints: [BodyJoint: [Double]]
            var ankles: [BodySide: [Double]]
            var evidence: FootPoseSample {
                .init(pose: .init(timestampMs: timestampMs, ball: .init(x: ball[0],y: ball[1]),
                    width: ball[2], height: ball[3], confidence: ball[4], imageAspect: ball[5],
                    joints: joints.mapValues { .init(x: $0[0],y: $0[1]) }),
                    ankles: ankles.mapValues { .init(x: $0[0],y: $0[1],confidence: $0[2]) })
            }
        }
        let id: String
        let expected: Bool
        let contactMs: Int
        let samples: [View]
    }
    private func rows(_ name: String = "moving-foot-device-contacts") throws -> [Row] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
    }

    @Test func ContinuityRecoversOnlyTheTwoReviewedKicksInTheNewRecording() throws {
        // Device clip 6B9D12FD-5B5A-404A-89AC-BB1B837EA657, SHA-256
        // bbb5eb2192f8d92972da29918bdc753683feb5feb247277f1984661872645e6d.
        // Reviewed recoveries: 117.354 s (standing knee), 191.567 s (weak ankle).
        let rows = try rows("pose-continuity-device-contacts")
        #expect(rows.count == 135)
        #expect(rows.filter(\.expected).map(\.id).sorted() == ["latest-2737", "latest-4159"])
        for row in rows {
            let samples = row.samples.map(\.evidence)
            let strict = MovingFootContactRules.contactTime(samples, at: row.contactMs, usePoseContinuity: false)
            let recovered = MovingFootContactRules.contactTime(samples, at: row.contactMs)
            #expect((strict == nil && recovered != nil) == row.expected, "\(row.id)")
            if let strict { #expect(recovered == strict, "Preserve observed contact: \(row.id)") }
        }
    }

    @Test func WeakImpactAnkleNeedsTwoConfidentBracketingObservations() throws {
        let row = try #require(rows("pose-continuity-device-contacts").first { $0.id == "latest-4159" })
        for change in ["missing", "contradictory", "weakAfter"] {
            let samples = row.samples.map { original in
                var s = original
                let dt = s.timestampMs-row.contactMs
                if dt == 33 {
                    if change == "missing" { s.ankles.removeValue(forKey: .left) }
                    if change == "contradictory" { s.ankles[.left] = [0.9, 0.1, 0.18] }
                }
                if change == "weakAfter", dt > 33, var ankle = s.ankles[.left] {
                    ankle[2] = 0.49; s.ankles[.left] = ankle
                }
                return s.evidence
            }
            #expect(MovingFootContactRules.contactTime(samples, at: row.contactMs) == nil, "\(change)")
        }
    }

    @Test func MovingSupportLegCannotSupplyAStableReferenceHeight() throws {
        let row = try #require(rows("pose-continuity-device-contacts").first { $0.id == "latest-2737" })
        let samples = row.samples.enumerated().map { index, original in
            var s = original
            if var knee = s.joints[.rightKnee] {
                knee[1] += index.isMultiple(of: 2) ? 0.08 : -0.08; s.joints[.rightKnee] = knee
            }
            return s.evidence
        }
        #expect(MovingFootContactRules.contactTime(samples, at: row.contactMs) == nil)
    }

    @Test func ReviewedMovingFeetQualifyButCatchesAndFloorDoNot() throws {
        let rows = try rows()
        #expect(rows.filter(\.expected).count == 15)
        for row in rows {
            #expect((MovingFootContactRules.contactTime(row.samples.map(\.evidence), at: row.contactMs) != nil) == row.expected,
                    "Reviewed contact \(row.id)")
            #expect((MovingFootContactRules.contactTime(row.samples.map(\.evidence), at: row.contactMs,
                allowsLiftedFoot: true) != nil) == row.expected, "Lifted-foot rule: \(row.id)")
        }
    }

    @Test func timed120FPSDeviceSamplesRecoverBothReviewedKicksButNotHeldBall() throws {
        // Original nomral_juggling_6.mov, SHA-256
        // de6af4939c1b4350b5d72123e1ba6b9bd99fa87a0df518538a93765389d3f2cd.
        // Reviewed foot contacts: 25.541 s and 28.416 s; hands: 7.491 s and 11.783 s.
        let rows = try rows("timed-foot-device-contacts")
        #expect(rows.count == 4)
        for row in rows {
            #expect((MovingFootContactRules.contactTime(row.samples.map(\.evidence), at: row.contactMs,
                allowsLiftedFoot: true) != nil) == row.expected, "\(row.id)")
        }
    }

    @Test func lowerKickRequiresStableConfidentSupportAndActualFootMotion() throws {
        let row = try #require(rows("timed-foot-device-contacts").first { $0.id == "normal6-3062" })
        let impact = try #require(row.samples.first { $0.timestampMs == row.contactMs })
        for change in ["missingSupport", "weakSupport", "movingSupport", "stationaryFoot", "floorHeight", "noBallReversal"] {
            let samples = try row.samples.map { original in
                var s = original
                if change == "missingSupport" { s.ankles.removeValue(forKey: .left) }
                if change == "weakSupport", var a = s.ankles[.left] { a[2] = 0.49; s.ankles[.left] = a }
                if change == "movingSupport", s.timestampMs < row.contactMs, var a = s.ankles[.left] {
                    a[1] -= 0.1; s.ankles[.left] = a
                }
                if change == "stationaryFoot", let hip = s.joints[.rightHip] {
                    let a = try #require(impact.ankles[.right]), h = try #require(impact.joints[.rightHip])
                    s.ankles[.right] = [hip[0]+a[0]-h[0],hip[1]+a[1]-h[1],0.9]
                }
                if change == "floorHeight" { s.ball[1] += 0.14 }
                if change == "noBallReversal" { s.ball[1] = impact.ball[1] }
                return s.evidence
            }
            #expect(MovingFootContactRules.contactTime(samples, at: row.contactMs, allowsLiftedFoot: true) == nil, "\(change)")
        }
    }

    @Test func MissingOrWeakAnklesCannotSupplyPositiveFootEvidence() throws {
        for row in try rows() where row.expected {
            for missing in [true,false] {
                let samples = row.samples.map { original in
                    var s = original
                    s.ankles = missing ? [:] : s.ankles.mapValues { [$0[0],$0[1],min(0.49,$0[2])] }
                    return s.evidence
                }
                #expect(MovingFootContactRules.contactTime(samples, at: row.contactMs) == nil, "\(row.id)")
            }
            #expect(MovingFootContactRules.contactTime(row.samples.map(\.evidence), at: row.contactMs+500) == nil)
            #expect(MovingFootContactRules.contactTime(row.samples.filter { $0.timestampMs != row.contactMs }.map(\.evidence),
                                                       at: row.contactMs) == nil)
        }
    }

    @Test func StationaryFootRelativeToHipCannotRecoverAContact() throws {
        for row in try rows() where row.expected {
            let first = row.samples[0]
            let samples = row.samples.map { original in
                var s = original
                for side in BodySide.allCases {
                    if let ankle = first.ankles[side], let hip = first.joints[side.hip],
                       let currentHip = s.joints[side.hip] {
                        s.ankles[side] = [currentHip[0]+ankle[0]-hip[0], currentHip[1]+ankle[1]-hip[1],0.9]
                    } else { s.ankles.removeValue(forKey: side) }
                }
                return s.evidence
            }
            #expect(MovingFootContactRules.contactTime(samples, at: row.contactMs) == nil, "\(row.id)")
        }
    }

    @Test func AFootSwingAloneWithoutABallReversalIsInsufficient() throws {
        for row in try rows() where row.expected {
            let contact = try #require(row.samples.first { $0.timestampMs == row.contactMs })
            let samples = row.samples.map { original in
                var s = original
                s.ball[1] = contact.ball[1]
                for side in BodySide.allCases { s.joints[side.hip] = contact.joints[side.hip] }
                return s.evidence
            }
            #expect(MovingFootContactRules.contactTime(samples, at: row.contactMs) == nil, "\(row.id)")
        }
    }
}
