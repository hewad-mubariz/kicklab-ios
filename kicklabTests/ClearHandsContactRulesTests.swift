import Foundation
import Testing
@testable import kicklab

struct ClearHandsContactRulesTests {
    typealias Sample = ClearHandsContactRules.Sample
    typealias Point = PosePoint
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct View: Decodable {
                let timestampMs: Int
                let ball: [Double]
                let joints: [BodyJoint: [Double]]
                var sample: Sample {
                    .init(timestampMs: timestampMs, ball: .init(x: ball[0], y: ball[1]),
                        width: ball[2], height: ball[3], confidence: ball[4], imageAspect: ball[5],
                        joints: joints.mapValues { .init(x: $0[0], y: $0[1]) })
                }
            }
            let id: String
            let contactMs: Int
            let expectedClear: Bool
            let samples: [View]
        }
        let cases: [Case]
    }
    private final class Resources {}

    @Test func reviewedDeviceFeetAndHandlingKeepTheirClearanceVerdicts() throws {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "clear-hands-device-contacts", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 27)
        for row in fixture.cases {
            #expect((ClearHandsContactRules.failure(row.samples.map(\.sample), at: row.contactMs) == nil) == row.expectedClear,
                    "Candidate \(row.id)")
        }
    }
    private var figure: [BodyJoint: Point] { [
        .leftShoulder: .init(x: 0.4, y: 0.25), .rightShoulder: .init(x: 0.6, y: 0.25),
        .leftHip: .init(x: 0.42, y: 0.55), .rightHip: .init(x: 0.58, y: 0.55),
        .leftElbow: .init(x: 0.25, y: 0.33), .rightElbow: .init(x: 0.75, y: 0.33),
        .leftWrist: .init(x: 0.15, y: 0.4), .rightWrist: .init(x: 0.85, y: 0.4)] }
    private func views(ball: Point = .init(x: 0.5, y: 0.4), aspect: Double = 1) -> [Sample] {
        [-33, 0, 33].map { offset in
            .init(timestampMs: 1000+offset,
                ball: .init(x: 0.5+(ball.x-0.5)/aspect, y: ball.y), width: 0.08/aspect, height: 0.08,
                confidence: 0.9, imageAspect: aspect,
                joints: figure.mapValues { .init(x: 0.5+($0.x-0.5)/aspect, y: $0.y) })
        }
    }
    private func replace(_ s: Sample, joints: [BodyJoint: Point]) -> Sample {
        .init(timestampMs: s.timestampMs, ball: s.ball, width: s.width, height: s.height,
              confidence: s.confidence, imageAspect: s.imageAspect, joints: joints)
    }

    @Test func clearChestAndRaisedFeetUseTheSameEvidenceWithoutAnkles() {
        for ball in [Point(x: 0.5, y: 0.4), Point(x: 0.5, y: 0.6), Point(x: 0.7, y: 0.65)] {
            #expect(ClearHandsContactRules.failure(views(ball: ball), at: 1000) == nil)
        }
        let noLegs = views().map { replace($0, joints: $0.joints.filter { $0.key != .leftHip && $0.key != .rightHip }) }
        #expect(ClearHandsContactRules.failure(noLegs, at: 1000) == nil)
    }

    @Test func aHiddenOrNearbyHandAtImpactCannotBeReplacedByOtherFrames() {
        for side in BodySide.allCases {
            var s = views(), joints = s[1].joints
            joints.removeValue(forKey: side.wrist); s[1] = replace(s[1], joints: joints)
            #expect(ClearHandsContactRules.failure(s, at: 1000) == .handsUncertain)
            joints[side.wrist] = .init(x: 0.5, y: 0.4); s[1] = replace(s[1], joints: joints)
            #expect(ClearHandsContactRules.failure(s, at: 1000) == .handsNearBall)
        }
    }

    @Test func aForearmCrossingTheBallCannotQualifyAsClearChest() {
        var s = views(), joints = s[1].joints
        joints[.leftElbow] = .init(x: 0.7, y: 0.4)
        s[1] = replace(s[1], joints: joints)
        #expect(ClearHandsContactRules.failure(s, at: 1000) == .handsNearBall)
    }

    @Test func independentLegRecoveryCannotClearAnAmbiguousChest() {
        for hiddenHand in [true, false] {
            let samples = views().map { view in
                var joints = view.joints
                if hiddenHand { joints.removeValue(forKey: .rightWrist) }
                else { joints[.rightWrist] = view.ball }
                return FootPoseSample(pose: replace(view, joints: joints), ankles: [:],
                    landmarks: joints.mapValues { .init(x: $0.x, y: $0.y, confidence: 0.9) })
            }
            let failure = ClearHandsContactRules.failure(samples.map(\.pose), at: 1000)
            #expect(failure == (hiddenHand ? .handsUncertain : .handsNearBall))
            #expect(CountingPolicy.current.body.allowsObservedLegRecovery(after: failure))
            #expect(ObservedLegContactRules.contactTime(samples, at: 1000,
                usesTemporalEvidence: CountingPolicy.current.body.usesTemporalEvidence) == nil)
        }
    }

    @Test func handsNeedClearanceBeforeAndAfterContact() {
        for i in [0, 2] {
            var s = views(), joints = s[i].joints
            joints[.rightWrist] = .init(x: 0.5, y: 0.4); s[i] = replace(s[i], joints: joints)
            #expect(ClearHandsContactRules.failure(s, at: 1000) == .handsNearBall)
        }
        #expect(ClearHandsContactRules.failure(Array(views().dropFirst()), at: 1000) == .insufficientContactViews)
        #expect(ClearHandsContactRules.failure(Array(views().dropLast()), at: 1000) == .insufficientContactViews)
        #expect(ClearHandsContactRules.failure(views(), at: 1500) == .insufficientContactViews)
    }

    @Test func aspectRatioDoesNotChangeClearance() {
        for aspect in [0.8, 1, 1.7778] {
            #expect(ClearHandsContactRules.failure(views(aspect: aspect), at: 1000) == nil)
        }
    }

    @Test func invalidBallOrMissingBodyCannotSupplyClearance() {
        var s = views()
        s[1] = replace(s[1], joints: [:])
        #expect(ClearHandsContactRules.failure(s, at: 1000) == .missingPose)
        #expect(ClearHandsContactRules.failure(views(ball: .init(x: .nan, y: 0.4)), at: 1000) == .invalidGeometry)
    }

    @Test func clearHandsAloneCannotAdmitABounceBesideTheFeet() {
        let low = views(ball: .init(x: 0.5, y: 0.91)).map { s in
            var joints = s.joints
            joints[.leftAnkle] = .init(x: 0.45, y: 0.86)
            joints[.rightAnkle] = .init(x: 0.55, y: 0.87)
            return replace(s, joints: joints)
        }
        #expect(ClearHandsContactRules.failure(low, at: 1000) == .lowContactNeedsFootEvidence)
    }
}
