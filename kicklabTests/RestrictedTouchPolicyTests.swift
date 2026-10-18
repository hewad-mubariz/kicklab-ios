import Foundation
import Testing
@testable import kicklab

struct RestrictedTouchPolicyTests {
    typealias Point = PosePoint
    private var figure: [BodyJoint: Point] { [
        .nose: .init(x: 0.5, y: 0.12),
        .leftShoulder: .init(x: 0.44, y: 0.22), .rightShoulder: .init(x: 0.56, y: 0.22),
        .leftHip: .init(x: 0.46, y: 0.48), .rightHip: .init(x: 0.54, y: 0.48),
        .leftKnee: .init(x: 0.46, y: 0.68), .rightKnee: .init(x: 0.54, y: 0.68),
        .leftAnkle: .init(x: 0.46, y: 0.88), .rightAnkle: .init(x: 0.54, y: 0.88)] }
    private func region(_ x: Double, _ y: Double, joints: [BodyJoint: Point]? = nil) -> RestrictedTouchPolicy.Region? {
        RestrictedTouchPolicy.region(ball: .init(x: x, y: y), width: 0.04, height: 0.04,
                                     joints: joints ?? figure, imageAspect: 1)
    }

    @Test func onlyHeadKneesAndFeetAreEligible() {
        #expect(region(0.5, 0.065) == .head)
        for x in [0.46, 0.54] {
            #expect(region(x, 0.65) == .knee)
            #expect(region(x, 0.89) == .foot)
            #expect(region(x, 0.93) == .foot)
            #expect(region(x, 0.55) == nil, "Thigh contacts are outside this experiment")
            #expect(region(x, 0.79) == nil, "Shin is not the foot")
        }
        #expect(region(0.8, 0.68) == nil, "Matching knee height alone is not contact")
        #expect(region(0.5, 0.01) == nil, "A ball well above the head is not contact")
    }

    @Test func torsoWithAnOccludedHandCannotBeCounted() {
        for y in [0.23, 0.30, 0.4, 0.47] {
            #expect(region(0.5, y) == nil, "No wrist detection is needed to reject torso contacts")
        }
        var oneHand = figure
        oneHand[.rightWrist] = .init(x: 0.7, y: 0.4)
        #expect(region(0.5, 0.3, joints: oneHand) == nil)
        #expect(region(0.43, 0.24) == nil, "Ball edge overlapping the torso is also rejected")
    }

    @Test func raisedKneeOverlappingTorsoIsAmbiguous() {
        var raised = figure
        raised[.leftKnee] = .init(x: 0.5, y: 0.4)
        #expect(region(0.5, 0.4, joints: raised) == nil)
    }

    @Test func missingOrInvalidPoseCannotAllowATouch() {
        #expect(region(0.46, 0.68, joints: [:]) == nil)
        var incomplete = figure; incomplete.removeValue(forKey: .leftShoulder)
        #expect(region(0.46, 0.68, joints: incomplete) == nil)
        var corrupt = figure; corrupt[.leftHip] = .init(x: .nan, y: 0.48)
        #expect(region(0.46, 0.68, joints: corrupt) == nil)
        #expect(region(.nan, 0.68) == nil)
    }

    @Test func sameGeometrySurvivesPortraitAndLandscapeNormalization() {
        for aspect in [0.5625, 1.0, 1.7778] {
            // Same geometry in frame-height units, with x translated to center.
            let joints = figure.mapValues { Point(x: 0.5 + ($0.x - 0.5) / aspect, y: $0.y) }
            for (x, y, expected) in [(0.5, 0.065, RestrictedTouchPolicy.Region.head),
                                     (0.46, 0.65, .knee), (0.54, 0.93, .foot)] {
                #expect(RestrictedTouchPolicy.region(ball: .init(x: 0.5 + (x - 0.5) / aspect, y: y),
                    width: 0.04 / aspect, height: 0.04, joints: joints, imageAspect: aspect) == expected)
            }
        }
    }

    @Test func lowToeRegionExtendsAcrossTheShinAndDoesNotRequireShoulders() {
        var lower = figure
        lower.removeValue(forKey: .leftShoulder)
        lower.removeValue(forKey: .rightShoulder)
        #expect(region(0.37, 0.87, joints: lower) == .foot)
        #expect(region(0.63, 0.87, joints: lower) == .foot)
        #expect(region(0.46, 0.79, joints: lower) == nil, "Do not expand upwards into the shin")
        #expect(region(0.46, 0.48, joints: lower) == nil, "Missing shoulders cannot qualify torso contact")
        lower.removeValue(forKey: .leftKnee)
        #expect(region(0.37, 0.87, joints: lower) == nil, "Visible leg geometry is still required")
    }

    @Test func reviewedToeContactsAreIndependentOfUncertainHands() throws {
        final class Resources {}
        let url = try #require(Bundle(for: Resources.self).url(forResource: "low-toe-taps-body", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        #expect(rows.count == 31)
        for row in rows {
            let frame = row["frame"] as! Int
            let time = row["contactMs"] as! Int
            let view = try #require((row["samples"] as! [[String: Any]]).first { ($0["timestampMs"] as! Int) == time })
            let ball = view["ball"] as! [Double]
            let joints = Dictionary(uniqueKeysWithValues: (view["joints"] as! [String: [Double]]).map { (BodyJoint(rawValue: $0.key)!, Point(x: $0.value[0], y: $0.value[1])) })
            let result = RestrictedTouchPolicy.region(ball: .init(x: ball[0], y: ball[1]), width: ball[2],
                height: ball[3], joints: joints, imageAspect: ball[5])
            if [692,737,1527].contains(frame) {
                #expect(result == nil, "Keep genuinely incomplete lower-leg geometry uncertain")
            } else {
                #expect(result == .foot, "Reviewed toe contact \(frame)")
            }
        }
    }

    @Test func sidewaysToeRegionCannotQualifyTheReviewedFloorBounce() throws {
        final class Resources {}
        let url = try #require(Bundle(for: Resources.self).url(forResource: "low-foot-floor-contact", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        let row = try #require(rows.first)
        let time = row["contactMs"] as! Int
        let view = try #require((row["samples"] as! [[String: Any]]).first { ($0["timestampMs"] as! Int) == time })
        let ball = view["ball"] as! [Double]
        let joints = Dictionary(uniqueKeysWithValues: (view["joints"] as! [String: [Double]]).map { (BodyJoint(rawValue: $0.key)!, Point(x: $0.value[0], y: $0.value[1])) })
        #expect(RestrictedTouchPolicy.region(ball: .init(x: ball[0], y: ball[1]), width: ball[2],
            height: ball[3], joints: joints, imageAspect: ball[5]) == nil,
            "The ball is below the ankle, beside the foot; widening toe reach must not accept this bounce")
    }
}
