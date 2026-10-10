import XCTest
@testable import kicklab

final class ShotTrailTests: XCTestCase {
    private let size = CGSize(width: 1080, height: 1920)

    /// Rests at the spot until 0.5 s, flies up the frame until 1.2 s, then is lost in the net.
    private func shot() -> BallEffectTrack {
        let frames = stride(from: 0.0, through: 1.2, by: 1.0 / 60).map { time -> RecordedFrame in
            let flight = max(0, time - 0.5) / 0.7
            let x = 0.3 + 0.3 * flight, y = 0.88 - 0.45 * flight, width = 0.09 - 0.06 * flight
            return RecordedFrame(time: time, x: x, y: y, width: width, height: width * 9 / 16, score: 0.9,
                                 smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: nil)
        }
        return BallEffectTrack(frames: frames)
    }

    func testTrailStaysOffWhileTheBallRests() {
        let frame = EffectFrame.shot(size: size, sourceSize: size, style: .fireTrail, intensity: 1, track: shot(), time: 0.4)
        XCTAssertEqual(frame.intensity, 0, accuracy: 0.001)
    }

    func testTrailCoversTheFlightBehindTheBall() throws {
        let frame = EffectFrame.shot(size: size, sourceSize: size, style: .limeRibbon, intensity: 1, track: shot(), time: 0.9)
        XCTAssertEqual(frame.style, 24)
        XCTAssertGreaterThan(frame.intensity, 0.9)
        let ages = frame.trail.map(\.w)
        // Struck at 0.5 s: the trail reaches back to take-off and not into the rest before it.
        XCTAssertEqual(try XCTUnwrap(ages.first), 0.4, accuracy: 0.04)
        XCTAssertEqual(ages, ages.sorted(by: >), "Oldest first, as the shader walks it")
        XCTAssertEqual(try XCTUnwrap(ages.last), 0, accuracy: 0.001)
        for point in frame.trail {
            XCTAssertTrue(frame.region.contains(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))))
        }
        XCTAssertLessThan(frame.velocity.y, 0, "Heading up the frame, toward the goal")
    }

    func testTrailLingersBrieflyAfterTheBallIsLost() {
        let soon = EffectFrame.shot(size: size, sourceSize: size, style: .glowTrail, intensity: 1, track: shot(), time: 1.4)
        XCTAssertGreaterThan(soon.visibility, 0.2)
        XCTAssertLessThan(soon.visibility, 1)
        XCTAssertEqual(soon.trail.first?.w ?? 0, 0.9, accuracy: 0.04, "The whole flight stays, ageing")
        XCTAssertEqual(soon.trail.last?.w ?? 0, 0.2, accuracy: 0.02, "Ending where the ball was last seen")
        let later = EffectFrame.shot(size: size, sourceSize: size, style: .glowTrail, intensity: 1, track: shot(), time: 1.8)
        XCTAssertEqual(later.visibility, 0, accuracy: 0.001)
    }

    /// Filmed at 25 fps, the blurred ball is missed for 0.12 s right after the strike.
    func testTrailBridgesTheMissRightAfterTheStrike() throws {
        var frames: [RecordedFrame] = []
        for step in 0...48 {
            let time = Double(step) / 25
            if time > 1.0 && time < 1.12 { continue }
            let flight = max(0, time - 1.0)
            let x = 0.5 + 0.02 * flight, y = 0.9 - 0.8 * flight, width = max(0.03, 0.12 - 0.25 * flight)
            frames.append(RecordedFrame(time: time, x: x, y: y, width: width, height: width * 9 / 16, score: 0.9,
                                        smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: nil))
        }
        let track = BallEffectTrack(frames: frames)
        let frame = EffectFrame.shot(size: size, sourceSize: size, style: .fireTrail, intensity: 1, track: track, time: 1.16)
        XCTAssertGreaterThan(frame.intensity, 0.9, "On as soon as the ball is picked up again")
        XCTAssertEqual(try XCTUnwrap(frame.trail.first?.w), 0.16, accuracy: 0.04, "Reaching back to the strike")
        let gaps = zip(frame.trail, frame.trail.dropFirst()).map { $0.w - $1.w }
        XCTAssertLessThan(gaps.max() ?? 1, 0.02, "Evenly spaced, with no hole after the strike")
    }

    func testNoneDrawsNothing() {
        let frame = EffectFrame.shot(size: size, sourceSize: size, style: .none, intensity: 1, track: shot(), time: 0.9)
        XCTAssertEqual(frame.style, 0)
        XCTAssertEqual(frame.intensity, 0)
    }

    func testShotStylesHaveTheirOwnShaderIDs() {
        let ids = ShotTrailStyle.allCases.filter { $0 != .none }.map(\.shaderID)
        XCTAssertEqual(ids.count, 10)
        XCTAssertEqual(Set(ids).count, 10)
        XCTAssertTrue(ids.allSatisfy { $0 >= 20 }, "Juggling effects keep 1–16")
    }
}
