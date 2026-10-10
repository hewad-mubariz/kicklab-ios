import XCTest
@testable import kicklab

final class MotionStyleTests: XCTestCase {
    private let points: [CaptureMotionPoint] = (0...120).map { index in
        let t = Double(index) / 30
        return CaptureMotionPoint(time: t, y: 0.8 - 0.5 * abs(sin(t * .pi)), x: 0.3 + t * 0.1)
    }

    func testPeaksUseCompletedMeasuredBouncesAndNeverFutureTouches() {
        let timeline = MotionStyleTimeline(points: points, touchTimes: [0, 1, 2, 3, 4])
        XCTAssertEqual(timeline.peaks.count, 4)
        XCTAssertEqual(timeline.peaks[0].height, 0.5, accuracy: 0.001)
        XCTAssertTrue(timeline.snapshot(at: 0.9, duration: 4).peaks.isEmpty)
        XCTAssertEqual(timeline.snapshot(at: 1.1, duration: 4).peaks.map(\.number), [1])
        XCTAssertEqual(timeline.snapshot(at: 4, duration: 4).peaks.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(timeline.snapshot(at: 1.1, duration: 4).peaks.map(\.number), [1], "Seeking backward must discard later peaks")
    }

    func testMissingTrackingDoesNotInventPeaksOrContinueTheBall() {
        let broken = points.map { $0.time > 0.4 && $0.time < 0.7 ? CaptureMotionPoint(time: $0.time, y: nil) : $0 }
        let timeline = MotionStyleTimeline(points: broken, touchTimes: [0, 1, 2, 3, 4])
        XCTAssertEqual(timeline.peaks.map(\.number), [2, 3, 4])
        let missing = timeline.snapshot(at: 0.5, duration: 4)
        XCTAssertNil(missing.currentPosition)
        XCTAssertNil(missing.bounce)
        XCTAssertNil(missing.flight, "No bounce in flight without tracking")
        XCTAssertEqual(missing.graph.status, "TRACK LOST")
        let stale = timeline.snapshot(at: 5, duration: 8)
        XCTAssertNil(stale.currentPosition)
        XCTAssertNil(stale.bounce)
        XCTAssertNil(stale.lift)
    }

    func testBounceSquashesLiftsAndReturnsToCircleIncludingWhenSeeking() throws {
        let timeline = MotionStyleTimeline(points: points, touchTimes: [0, 1, 2, 3, 4])
        let contact = try XCTUnwrap(timeline.snapshot(at: 1, duration: 4).bounce)
        XCTAssertGreaterThan(contact.scale.width, 1)
        XCTAssertLessThan(contact.scale.height, 1)
        let lift = try XCTUnwrap(timeline.snapshot(at: 1.16, duration: 4).bounce)
        XCTAssertGreaterThan(lift.scale.height, 1)
        XCTAssertLessThan(lift.scale.width, 1)
        XCTAssertEqual(timeline.snapshot(at: 1.5, duration: 4).bounce?.scale, CGSize(width: 1, height: 1))
        XCTAssertEqual(timeline.snapshot(at: 1, duration: 4).bounce?.scale, contact.scale)
        XCTAssertEqual(MotionStyleSnapshot.Bounce.scale(age: 0, reduceMotion: true), CGSize(width: 1, height: 1))
    }

    func testInvalidDataIsSafeAndSelectionCatalogKeepsDefaultFirst() {
        let state = MotionStyleTimeline(points: [.init(time: .nan, y: .nan, x: .infinity),
                                                  .init(time: 0, y: .infinity, x: .nan)],
                                        touchTimes: [.nan, .infinity, -1, 0, 0]).snapshot(at: .nan)
        XCTAssertNil(state.currentPosition)
        XCTAssertNil(state.bounce)
        XCTAssertTrue(state.peaks.isEmpty)
        XCTAssertTrue(state.arcs.isEmpty)
        XCTAssertEqual(state.touchTimes, [0])
        XCTAssertEqual(MotionStyle.allCases.first, .ballMotion)
        XCTAssertEqual(MotionStyle.allCases.count, 10)
    }

    func testBestHeightOnlyCountsBouncesThatHaveHappened() {
        let timeline = MotionStyleTimeline(points: points, touchTimes: [0, 1, 2, 3, 4])
        XCTAssertEqual(timeline.snapshot(at: 0.5, duration: 4).best, 0)
        let after = timeline.snapshot(at: 1.2, duration: 4)
        XCTAssertGreaterThan(after.best, 0.9)
        XCTAssertEqual(after.arcs.map(\.number), [1])
        XCTAssertNotNil(after.flight, "The second bounce is in the air")
        XCTAssertEqual(after.flight?.start, 1)
    }

    func testComboGrowsWithSteadyTouchesAndBreaksOnAWaitOrAnUnevenGap() {
        let steady = (0..<12).map { Double($0) * 0.7 }
        let running = MotionStyleSnapshot.combo(played: steady, now: 7.8)
        XCTAssertEqual(running.streak, 12)
        XCTAssertEqual(running.level, 2)
        XCTAssertEqual(running.fill, 2)
        XCTAssertNil(running.brokenAge)
        let waited = MotionStyleSnapshot.combo(played: steady, now: 7.7 + 1.3)
        XCTAssertEqual(waited.streak, 0)
        XCTAssertNotNil(waited.brokenAge)
        XCTAssertEqual(waited.best, 12)
        let uneven = steady.prefix(5) + [2.8 + 1.9, 4.7 + 0.7]
        let restarted = MotionStyleSnapshot.combo(played: Array(uneven), now: 5.5)
        XCTAssertEqual(restarted.streak, 2, "A far-too-long gap restarts the streak")
        XCTAssertEqual(restarted.best, 5)
    }
}
