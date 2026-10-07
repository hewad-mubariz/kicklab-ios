import Testing
@testable import kicklab

struct JugglingContactRulesTests {
    typealias Point = JugglingContactRules.Point
    private var figure: [String: Point] { [
        "nose": Point(x: 0.5, y: 0.12),
        "left_shoulder": Point(x: 0.44, y: 0.22), "right_shoulder": Point(x: 0.56, y: 0.22),
        "left_elbow": Point(x: 0.42, y: 0.34), "right_elbow": Point(x: 0.58, y: 0.34),
        "left_wrist": Point(x: 0.42, y: 0.46), "right_wrist": Point(x: 0.58, y: 0.46),
        "left_hip": Point(x: 0.46, y: 0.48), "right_hip": Point(x: 0.54, y: 0.48),
        "left_knee": Point(x: 0.46, y: 0.68), "right_knee": Point(x: 0.54, y: 0.68),
        "left_ankle": Point(x: 0.46, y: 0.88), "right_ankle": Point(x: 0.54, y: 0.88)] }

    @Test func handsDoNotCountButLegsHeadAndChestRemainEligible() {
        #expect(JugglingContactRules.isHand(ball: Point(x: 0.42, y: 0.44), width: 0.04, joints: figure))
        for point in [Point(x: 0.46, y: 0.93), Point(x: 0.46, y: 0.68), Point(x: 0.46, y: 0.55),
                      Point(x: 0.5, y: 0.3), Point(x: 0.5, y: 0.08)] {
            #expect(!JugglingContactRules.isHand(ball: point, width: 0.04, joints: figure))
        }
    }

    @Test func twoHandGripIsDifferentFromArmsHangingBesideTheBall() {
        let ball = Point(x: 0.5, y: 0.46)
        #expect(!JugglingContactRules.isHand(ball: ball, width: 0.06, joints: figure))
        var gripping = figure
        gripping["left_wrist"] = Point(x: 0.465, y: 0.46)
        gripping["right_wrist"] = Point(x: 0.535, y: 0.46)
        #expect(JugglingContactRules.isHand(ball: ball, width: 0.06, joints: gripping))
    }

    @Test func missingPoseAndAmbiguousArmLegOverlapDoNotInventAHand() {
        #expect(!JugglingContactRules.isHand(ball: Point(x: 0.5, y: 0.5), width: 0.05, joints: [:]))
        var overlap = figure
        overlap["left_wrist"] = Point(x: 0.46, y: 0.70)
        #expect(!JugglingContactRules.isHand(ball: Point(x: 0.46, y: 0.69), width: 0.04, joints: overlap))
    }
}
