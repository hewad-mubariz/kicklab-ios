#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallPixelTrackingTests: XCTestCase {
    private let size = CGSize(width: 640, height: 360)
    private func ball(_ x: Double, _ y: Double, _ d: Double, score: Double = 0.9) -> Detection {
        .init(score: score, x: x / 640, y: y / 360, width: d / 640, height: d / 360)
    }
    private func image(_ balls: [(Double, Double, Double)]) -> WallBallPixelTracker.Image {
        var values = [UInt8](repeating: 0, count: 640 * 360)
        for y in 0..<360 { for x in 0..<640 {
            var v = 32.0 + Double((x * 7 + y * 11) % 9)
            for (cx, cy, d) in balls {
                let u = (Double(x) - cx) / (d / 2), w = (Double(y) - cy) / (d / 2)
                if u * u + w * w <= 1 {
                    v = 130 + 50 * sin(u * 9 + w * 3) * cos(w * 8) + 20 * u
                }
            }
            values[y * 640 + x] = UInt8(clamping: Int(v))
        } }
        return .init(luma: values, width: 640, height: 360, size: size)
    }

    func testMeasuredTranslationAndShrinkingAcrossLeftCentreAndRight() throws {
        for x in [100.0, 320.0, 530.0] {
            var tracker = WallBallPixelTracker()
            tracker.seed(ball(x, 100, 44), image: image([(x, 100, 44)]), at: 1)
            let matched = try XCTUnwrap(tracker.update(image([(x + 14, 111, 40)]), at: 1 + 1.0 / 60))
            XCTAssertEqual(matched.x * 640, x + 14, accuracy: 2)
            XCTAssertEqual(matched.y * 360, 111, accuracy: 2)
            XCTAssertEqual(matched.width * 640, 40, accuracy: 3)
            XCTAssertTrue(WallBallPixelTracker.agrees(matched, model: ball(x + 14, 111, 40), size: size))
        }
    }

    func testNoBallAndAmbiguousTwinCannotSupplyAContactPosition() {
        var tracker = WallBallPixelTracker()
        tracker.seed(ball(300, 100, 30), image: image([(300, 100, 30)]), at: 1)
        XCTAssertNil(tracker.update(image([]), at: 1.03))
        tracker.seed(ball(300, 100, 30), image: image([(300, 100, 30)]), at: 2)
        XCTAssertNil(tracker.update(image([(279, 100, 30), (321, 100, 30)]), at: 2.05))
    }

    func testSparseRecordingGapExpiresInsteadOfTrackingBackground() {
        var tracker = WallBallPixelTracker()
        tracker.seed(ball(300, 100, 44), image: image([(300, 100, 44)]), at: 1)
        XCTAssertNil(tracker.update(image([(380, 120, 35)]), at: 1.10))
        // A plausible image after expiry is insufficient without another RF seed.
        XCTAssertNil(tracker.update(image([(390, 120, 35)]), at: 1.12))
    }

    func testSeedAgeAndResetCannotBeExtendedBySuccessfulImageMatches() {
        var tracker = WallBallPixelTracker()
        let still = image([(300, 100, 44)])
        tracker.seed(ball(300, 100, 44), image: still, at: 1)
        for n in 1...11 { _ = tracker.update(still, at: 1 + Double(n) / 60) }
        XCTAssertNil(tracker.update(still, at: 1.20))
        tracker.seed(ball(300, 100, 44), image: still, at: 2)
        tracker.reset()
        XCTAssertNil(tracker.update(still, at: 2.02))
        tracker.seed(ball(300, 100, 44, score: 0.19), image: still, at: 3)
        XCTAssertNil(tracker.update(still, at: 3.02))
    }

    func testIndependentModelMustConfirmPositionSizeAndIdentity() {
        let tracked = ball(300, 100, 40)
        XCTAssertFalse(WallBallPixelTracker.agrees(tracked, model: nil, size: size))
        XCTAssertFalse(WallBallPixelTracker.agrees(tracked, model: ball(300, 100, 40, score: 0.19), size: size))
        XCTAssertFalse(WallBallPixelTracker.agrees(tracked, model: ball(370, 100, 40), size: size))
        XCTAssertFalse(WallBallPixelTracker.agrees(tracked, model: ball(300, 100, 55), size: size))
        XCTAssertTrue(WallBallPixelTracker.agrees(tracked, model: ball(302, 101, 42), size: size))
    }

    func testCaptureBacklogKeepsChronologyAndBoundsOverload() {
        var buffer = WallTrackingFrameBuffer<Int>()
        buffer.setBuffered(true)
        XCTAssertEqual(buffer.offer(0, at: 0), 0)
        for n in 1...12 { XCTAssertNil(buffer.offer(n, at: Double(n) / 60)) }
        XCTAssertEqual(buffer.finish(), Array(7...12))
        XCTAssertEqual(buffer.dropped, 6)
        XCTAssertNil(buffer.offer(13, at: 13.0 / 60))
        XCTAssertEqual(buffer.finish(), [13])
        XCTAssertEqual(buffer.finish(), [])
        XCTAssertEqual(buffer.offer(14, at: 14.0 / 60), 14)
    }

    func testModeChangesAndCancellationDiscardPendingFrames() {
        var buffer = WallTrackingFrameBuffer<Int>()
        XCTAssertEqual(buffer.offer(0, at: 0), 0)
        _ = buffer.offer(1, at: 0.01); _ = buffer.offer(2, at: 0.02)
        XCTAssertEqual(buffer.finish(), [2]) // setup retains newest only
        buffer.setBuffered(true)
        _ = buffer.offer(3, at: 0.03); _ = buffer.offer(4, at: 0.04)
        buffer.cancelPending()
        XCTAssertTrue(buffer.finish().isEmpty)
        XCTAssertEqual(buffer.offer(5, at: 1), 5)
        XCTAssertNil(buffer.offer(6, at: 0.99))
        XCTAssertTrue(buffer.finish().isEmpty)
    }
}
#endif
