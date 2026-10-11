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

    @Test func visibleFingersCanConfirmContactBeyondTheBodyWrist() {
        let ball = Point(x: 0.5, y: 0.4)
        let wrist = Point(x: 0.5, y: 0.48)
        let points: [JugglingContactRules.HandLandmark] = [
            .init(finger: 0, x: wrist.x, y: wrist.y, confidence: 0.8),
            .init(finger: 2, x: 0.49, y: 0.43, confidence: 0.8),
            .init(finger: 2, x: 0.49, y: 0.44, confidence: 0.8),
            .init(finger: 3, x: 0.51, y: 0.43, confidence: 0.8)]
        func verdict(_ landmarks: [JugglingContactRules.HandLandmark], wrists: [Point] = [Point(x: 0.5, y: 0.48)]) -> Bool {
            JugglingContactRules.fingersTouchBall(ball: ball, width: 0.1, height: 0.08,
                bodyWrists: wrists, landmarks: landmarks)
        }
        #expect(verdict(points))
        #expect(!verdict(Array(points.prefix(3))), "A single finger is insufficient")
        #expect(!verdict(points, wrists: []), "Must belong to the visible player's body pose")
        #expect(!verdict(points, wrists: [Point(x: 0.8, y: 0.8)]))
        #expect(!verdict(points.map { var p = $0; p.confidence = 0.2; return p }))
        #expect(!verdict(points.map { var p = $0; if p.finger > 0 { p.y += 0.1 }; return p }),
                "Nearby fingers without ball overlap are insufficient")
    }

    @Test func fingerFallbackCannotOverrideAmbiguousLegOrHeadContacts() {
        for y in [0.08, 0.12, 0.47, 0.55, 0.68, 0.93] {
            #expect(!JugglingContactRules.canResolveTorsoOverlap(ball: Point(x: 0.5, y: y),
                height: 0.04, joints: figure))
        }
        #expect(JugglingContactRules.canResolveTorsoOverlap(ball: Point(x: 0.5, y: 0.3),
            height: 0.04, joints: figure))
        #expect(!JugglingContactRules.canResolveTorsoOverlap(ball: Point(x: 0.5, y: 0.3),
            height: 0.04, joints: [:]))
    }
}
