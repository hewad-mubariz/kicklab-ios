import XCTest
@testable import kicklab

final class ShotFlightTests: XCTestCase {
    /// At rest until 0.5 s, then 0.7 s of flight; `bulge` pushes the middle of the path sideways.
    private func shot(bulge: Double) -> BallEffectTrack {
        let frames = stride(from: 0.0, through: 1.2, by: 1.0 / 60).map { time -> RecordedFrame in
            let t = max(0, time - 0.5) / 0.7
            let x = 0.35 + 0.2 * t + bulge * sin(.pi * t), y = 0.9 - 0.5 * t, width = 0.08 - 0.05 * t
            return RecordedFrame(time: time, x: x, y: y, width: width, height: width * 9 / 16, score: 0.9,
                                 smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: nil)
        }
        return BallEffectTrack(frames: frames)
    }

    func testFindsTheFlightFromTheStrike() throws {
        let flight = try XCTUnwrap(ShotFlight.find(in: shot(bulge: 0), aspect: 9.0 / 16))
        XCTAssertEqual(flight.launch, 0.5, accuracy: 0.04, "Starts at the strike, not during the rest")
        XCTAssertEqual(flight.airTime, 0.7, accuracy: 0.05)
        XCTAssertEqual(flight.phase(at: 0.3), .waiting)
        XCTAssertEqual(flight.phase(at: 0.9), .flying)
        XCTAssertEqual(flight.phase(at: 1.5), .done)
    }

    func testStraightAndCurvedShots() throws {
        let straight = try XCTUnwrap(ShotFlight.find(in: shot(bulge: 0), aspect: 9.0 / 16))
        XCTAssertLessThan(straight.bend, 0.04)
        XCTAssertEqual(straight.curveLabel, "Straight")
        let curled = try XCTUnwrap(ShotFlight.find(in: shot(bulge: 0.08), aspect: 9.0 / 16))
        // 0.08 of the width is 0.045 of the height; against a 0.51-long line that is a bend of about 0.086.
        XCTAssertEqual(curled.bend, 0.086, accuracy: 0.01)
        // Bulging right of its line, it curls back to the left.
        XCTAssertEqual(curled.bulge, 1)
        XCTAssertTrue(curled.curveLabel.hasSuffix("left"), curled.curveLabel)
        XCTAssertEqual(curled.points[curled.bendIndex].time, 0.85, accuracy: 0.08, "Widest near the middle")
    }

    /// Seen from behind, a lofted shot climbs up the picture, then drops back while it flies away.
    func testALoftedShotDips() throws {
        let lofted = stride(from: 0.0, through: 1.2, by: 1.0 / 60).map { time -> RecordedFrame in
            let t = max(0, time - 0.5) / 0.7
            let x = 0.5 + 0.05 * t, y = 0.9 - 2.0 * t + 1.6 * t * t, width = 0.08 - 0.05 * t
            return RecordedFrame(time: time, x: x, y: y, width: width, height: width * 9 / 16, score: 0.9,
                                 smoothedX: x, smoothedY: y, vy: 0, motion: .unknown, detected: true, person: nil)
        }
        let flight = try XCTUnwrap(ShotFlight.find(in: BallEffectTrack(frames: lofted), aspect: 9.0 / 16))
        XCTAssertTrue(flight.dips)
        XCTAssertEqual(flight.curveLabel, "Dips")
    }

    /// The graphs show the ball resting before the kick, so the flight keeps the second before it.
    func testTheSecondBeforeTheKickIsKept() throws {
        let flight = try XCTUnwrap(ShotFlight.find(in: shot(bulge: 0), aspect: 9.0 / 16))
        let lead = try XCTUnwrap(flight.lead.first)
        XCTAssertEqual(flight.launch - lead.time, 0.5, accuracy: 0.05, "From the start of the track, at most a second back")
        XCTAssertLessThan(try XCTUnwrap(flight.lead.last).time, flight.launch)
        XCTAssertTrue(flight.lead.allSatisfy { abs($0.y - 0.9) < 0.001 }, "Resting on the spot")
    }

    /// The ball's size in the picture shrinks to about a third: it ends that many times farther away.
    func testDepthGrowsWithTheFlightAndNeverComesBack() throws {
        let flight = try XCTUnwrap(ShotFlight.find(in: shot(bulge: 0), aspect: 9.0 / 16))
        XCTAssertEqual(flight.depth(at: 0.2), 1, "Before the kick")
        let sizes = try XCTUnwrap(flight.points.first?.radius) / XCTUnwrap(flight.points.last?.radius)
        XCTAssertGreaterThan(flight.depthRatio, 2.2)
        // Sizes are smoothed over neighbouring frames, so allow one frame of shrink.
        XCTAssertEqual(flight.depthRatio, sizes, accuracy: sizes * 0.06)
        let samples = stride(from: flight.launch, through: flight.end, by: 0.02).map { flight.depth(at: $0) }
        XCTAssertEqual(samples, samples.sorted(), "Only ever farther")
        XCTAssertEqual(try XCTUnwrap(samples.last), flight.depthRatio, accuracy: 0.001)
    }

    func testABallThatNeverMovesHasNoFlight() {
        let frames = stride(from: 0.0, through: 1.0, by: 1.0 / 60).map { time in
            RecordedFrame(time: time, x: 0.5, y: 0.8, width: 0.08, height: 0.045, score: 0.9,
                          smoothedX: 0.5, smoothedY: 0.8, vy: 0, motion: .unknown, detected: true, person: nil)
        }
        XCTAssertNil(ShotFlight.find(in: BallEffectTrack(frames: frames), aspect: 9.0 / 16))
    }
}
