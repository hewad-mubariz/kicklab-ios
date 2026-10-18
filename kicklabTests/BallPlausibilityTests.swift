import XCTest
@testable import kicklab

final class BallPlausibilityTests: XCTestCase {
    private func ball(_ x: Double, _ y: Double = 0.5, score: Double = 0.45,
                      width: Double = 0.1, height: Double = 0.06) -> Detection {
        Detection(score: score, x: x, y: y, width: width, height: height)
    }

    func testRFPolicyIsSeparateFromLegacyConfidenceCalibration() {
        XCTAssertEqual(BallPlausibility.Policy.forResource("RFDETRSmallRecovery040FP32"), .rfDetrAssociationV1)
        XCTAssertEqual(BallPlausibility.Policy.forResource("RFDETRSmallRecovery040FP16"), .rfDetrAssociationV1)
        XCTAssertEqual(BallPlausibility.Policy.forResource("KickLabYOLOXTinyFineTuned"), .legacy)
        var legacy = BallPlausibility()
        _ = legacy.accept(ball(0.2, score: 0.9), frame: 0, timestampMs: 0)
        XCTAssertNotNil(legacy.accept(ball(0.9, score: 0.3), frame: 1, timestampMs: 33))
    }

    func testWeakNearbyBallAndFastReversalSurviveAtDifferentCadences() {
        for interval in [8, 17, 33, 67, 100] {
            var gate = BallPlausibility(policy: .rfDetrAssociationV1)
            _ = gate.accept(ball(0.4, 0.4, score: 0.9), frame: 0, timestampMs: 0)
            let distance = Double(interval) / 1000 * 1.5
            _ = gate.accept(ball(0.4, 0.4 + distance, score: 0.9), frame: 1, timestampMs: interval)
            XCTAssertNotNil(gate.accept(ball(0.4, 0.4, score: 0.41), frame: 2, timestampMs: 2 * interval),
                            "An observed low-confidence reversal at \(interval) ms must remain available to contact validation")
        }
    }

    func testElapsedTimeControlsAssociationRatherThanFrameNumbers() {
        for frames in [[0, 1, 2], [0, 20, 800]] {
            var gate = BallPlausibility(policy: .rfDetrAssociationV1)
            _ = gate.accept(ball(0.3, score: 0.9), frame: frames[0], timestampMs: 0)
            _ = gate.accept(ball(0.31, score: 0.9), frame: frames[1], timestampMs: 100)
            XCTAssertNil(gate.accept(ball(0.8), frame: frames[2], timestampMs: 200))
        }
    }

    func testRejectedObjectCannotMoveAnchorAndReturningBallSurvives() {
        var gate = BallPlausibility(policy: .rfDetrAssociationV1)
        _ = gate.accept(ball(0.4, score: 0.9), frame: 0, timestampMs: 0)
        _ = gate.accept(ball(0.41, score: 0.9), frame: 1, timestampMs: 67)
        XCTAssertNil(gate.accept(ball(0.9), frame: 2, timestampMs: 100))
        XCTAssertNil(gate.accept(ball(0.9), frame: 3, timestampMs: 300))
        XCTAssertNotNil(gate.accept(ball(0.43, score: 0.41), frame: 4, timestampMs: 320))
        XCTAssertEqual(gate.rejectedJump, 2)
    }

    func testStartupLongGapAndStrongReacquisitionDoNotLockOutRealBall() {
        var gate = BallPlausibility(policy: .rfDetrAssociationV1)
        _ = gate.accept(ball(0.9), frame: 0, timestampMs: 0)
        XCTAssertNotNil(gate.accept(ball(0.3, score: 0.5), frame: 1, timestampMs: 33), "Weak startup guesses do not establish a lock")
        XCTAssertNotNil(gate.accept(ball(0.3, score: 0.9), frame: 2, timestampMs: 67))
        XCTAssertNotNil(gate.accept(ball(0.9, score: 0.9), frame: 3, timestampMs: 100), "Strong observations can reacquire immediately")
        XCTAssertNotNil(gate.accept(ball(0.2), frame: 4, timestampMs: 451), "Long-gap observations start a new association")
    }

    func testResetAndClockDiscontinuityDiscardOldAssociation() {
        var gate = BallPlausibility(policy: .rfDetrAssociationV1)
        _ = gate.accept(ball(0.2, score: 0.9), frame: 0, timestampMs: 1000)
        XCTAssertNotNil(gate.accept(ball(0.9), frame: 1, timestampMs: 900))
        _ = gate.accept(ball(0.2, score: 0.9), frame: 2, timestampMs: 2000)
        gate.reset()
        XCTAssertNotNil(gate.accept(ball(0.9), frame: 3, timestampMs: 2017))
        XCTAssertEqual(gate.rejectedJump, 0)
    }

    func testRejectedMaskIsRemovedButPersonAndMaskModelIdentityRemain() {
        var gate = BallPlausibility(policy: .rfDetrAssociationV1)
        _ = gate.accept(ball(0.2, score: 0.9), frame: 0, timestampMs: 0)
        let person = ball(0.4, score: 0.9)
        let mask = BallMask(rect: .init(x: 0.8, y: 0.4, width: 0.1, height: 0.1), width: 1, height: 1, alpha: [255])
        let filtered = gate.filter(FrameDetections(ball: ball(0.9), person: person, ballMask: mask, usesBallMasks: true),
                                   frame: 1, timestampMs: 33)
        XCTAssertNil(filtered.ball)
        XCTAssertNil(filtered.ballMask)
        XCTAssertEqual(filtered.person?.x, person.x)
        XCTAssertTrue(filtered.usesBallMasks)
    }

    func testRetainedDeviceObservationsRemoveOnlyLabeledBackgroundSwitches() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                struct Observation: Decodable { let frame, timestampMs: Int; let ball: [Double] }
                let id: String
                let expectedRejectedFrames: [Int]
                let observations: [Observation]
            }
            let cases: [Case]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ball-association-device-observations.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for item in fixture.cases {
            var gate = BallPlausibility(policy: .rfDetrAssociationV1)
            var rejected: [Int] = []
            for observation in item.observations {
                let b = observation.ball
                let detection = Detection(score: b[0], x: b[1], y: b[2], width: b[3], height: b[4])
                if gate.accept(detection, frame: observation.frame, timestampMs: observation.timestampMs) == nil {
                    rejected.append(observation.frame)
                }
            }
            XCTAssertEqual(rejected, item.expectedRejectedFrames, item.id)
        }
    }
}
