import CoreGraphics
import XCTest
@testable import kicklab

/// Motion smear = track velocity × exposure, with exposure measured from how much
/// detector boxes stretch along the motion. Sharp footage must stay sharp.
final class BallMotionSmearTests: XCTestCase {
    private let size = CGSize(width: 720, height: 1280)

    /// A ball moving at `speed` px/s along `angle`, with boxes stretched by speed × `exposure`.
    private func track(speed: Double, angle: Double, exposure: Double, fps: Double = 60, count: Int = 90) -> BallEffectTrack {
        let d = 60.0, vx = cos(angle)*speed, vy = sin(angle)*speed
        let frames = (0..<count).map { i -> RecordedFrame in
            let t = Double(i)/fps
            // Bounce inside the frame so the ball never touches an edge.
            let phase = (Double(i).truncatingRemainder(dividingBy: 30)) < 15 ? 1.0 : -1.0
            let k = Double(i % 15)/fps
            let x = 360+phase*vx*(k-0.125), y = 640+phase*vy*(k-0.125)
            let stretch = speed*exposure
            // The bounding box of a disc smeared by `stretch` along `angle`.
            let w = d+abs(cos(angle))*stretch, h = d+abs(sin(angle))*stretch
            return RecordedFrame(time: t, x: x/size.width, y: y/size.height, width: w/size.width, height: h/size.height,
                                 score: 0.9, smoothedX: x/size.width, smoothedY: y/size.height, vy: 0, motion: .unknown,
                                 detected: true, person: nil)
        }
        return BallEffectTrack(frames: frames)
    }

    func testExposureRecoveredFromBoxStretch() {
        for angle in [0.0, .pi/2, .pi/6] {
            let t = track(speed: 900, angle: angle, exposure: 0.007)
            XCTAssertEqual(t.exposure(size: size), 0.007, accuracy: 0.0015, "angle \(angle)")
        }
    }

    func testDiagonalMotionLeavesBoxesSquareAndGivesNoEvidence() {
        // An axis-aligned box cannot show a 45° smear; it must not pull exposure to zero
        // when other frames have evidence, and alone it yields no measurement.
        let t = track(speed: 900, angle: .pi/4, exposure: 0.007)
        XCTAssertEqual(t.exposure(size: size), 0)
    }

    func testSharpFootageHasNoSmearAtAnySpeed() {
        let t = track(speed: 1500, angle: 0.3, exposure: 0)
        XCTAssertEqual(t.exposure(size: size), 0, accuracy: 1e-9)
        XCTAssertEqual(t.smear(at: 20.0/60, size: size), .zero)
    }

    func testSmearFollowsVelocityTimesExposureAndScalesWithResolution() {
        let t = track(speed: 900, angle: .pi/2, exposure: 0.007)
        let s = t.smear(at: 5.0/60, size: size)
        XCTAssertEqual(abs(s.dy), 900*t.exposure(size: size), accuracy: 0.5)
        XCTAssertEqual(s.dx, 0, accuracy: 0.5)
        let doubled = t.smear(at: 5.0/60, size: CGSize(width: 1440, height: 2560))
        XCTAssertEqual(abs(doubled.dy), 2*abs(s.dy), accuracy: 0.5, "Normalized track, pixel smear")
    }

    func testTooFewObservationsGiveNoExposure() {
        let t = track(speed: 900, angle: 0, exposure: 0.007, count: 10)
        XCTAssertEqual(t.exposure(size: size), 0)
    }
}
