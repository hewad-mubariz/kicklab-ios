#if WALL_GAMES_PREVIEW
import XCTest
@testable import kicklab

@MainActor final class WallDisplayDelayTests: XCTestCase {
    func testDroppedFramesStillUseElapsedTimeAndSequenceFinishes() {
        let test = WallArcadeDisplayDelay()
        test.open()
        test.start(.sequence, at: 100)
        defer { test.close() }
        test.advance(to: 102.125)
        XCTAssertEqual(test.frame.milliseconds, 2_125)
        XCTAssertEqual(test.frame.pulse, 3)
        XCTAssertTrue(test.frame.lit)
        test.advance(to: 110.5)
        XCTAssertEqual(test.frame.milliseconds, 10_000)
        XCTAssertFalse(test.running)
        XCTAssertFalse(test.frame.lit)
    }

    func testRepeatedTapReplacesTheOldSignalWithoutAnOldFinish() {
        let test = WallArcadeDisplayDelay()
        test.open()
        test.start(.tap, at: 100)
        test.advance(to: 101)
        test.start(.tap, at: 102)
        defer { test.close() }
        test.advance(to: 103)
        XCTAssertEqual(test.frame.run, 2)
        XCTAssertEqual(test.frame.milliseconds, 1_000)
        XCTAssertTrue(test.running)
        XCTAssertFalse(test.frame.lit)
    }

    func testClosingOrStoppingCannotLeaveAFlashingProjector() {
        let test = WallArcadeDisplayDelay()
        test.open()
        test.start(.sequence, at: 100)
        test.stop()
        let stopped = test.frame
        test.advance(to: 101)
        XCTAssertEqual(test.frame, stopped)
        XCTAssertFalse(test.frame.lit)
        test.close()
        XCTAssertFalse(test.presented)
        test.start(.tap, at: 102)
        XCTAssertFalse(test.running)
        test.open()
        XCTAssertEqual(test.frame, .init())
        test.close()
    }
}
#endif
