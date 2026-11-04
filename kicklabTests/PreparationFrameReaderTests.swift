import AVFoundation
import XCTest
@testable import kicklab

final class PreparationFrameReaderTests: XCTestCase {
    func testRangesContainEveryRequestedFrameAndStayOnCompositionClock() throws {
        let step = CMTime(value: 1001, timescale: 60000), duration = CMTime(seconds: 40, preferredTimescale: 60000)
        let times = [0.0, 0.033, 9.876, 38.700, 40.0]
        let ranges = try XCTUnwrap(PreparationFrameReader.ranges(times: times, frameDuration: step, duration: duration))
        for time in times {
            XCTAssertTrue(ranges.contains { $0.start.seconds <= time && $0.end.seconds >= time })
        }
        for range in ranges {
            XCTAssertGreaterThan(range.duration.seconds, 0)
            XCTAssertGreaterThanOrEqual(range.start.seconds, 0)
            XCTAssertLessThanOrEqual(range.end.seconds, 40)
            let frame = range.start.seconds / step.seconds
            XCTAssertEqual(frame, frame.rounded(), accuracy: 1e-9)
        }
    }
    func testNearbyRequestsShareAWindowWithoutDroppingEither() throws {
        let ranges = try XCTUnwrap(PreparationFrameReader.ranges(times: [5.0, 5.1, 12.0],
            frameDuration: CMTime(value: 1, timescale: 60), duration: CMTime(seconds: 40, preferredTimescale: 600)))
        XCTAssertEqual(ranges.count, 2)
        XCTAssertLessThan(ranges[0].start.seconds, 5)
        XCTAssertGreaterThan(ranges[0].end.seconds, 5.1)
    }
    func testDenseOrInvalidRequestsFallBackToSequentialReading() {
        let step = CMTime(value: 1, timescale: 60), duration = CMTime(seconds: 40, preferredTimescale: 600)
        for times in [[Double.nan], [-0.1], [40.1], [], stride(from: 0.0, through: 39.9, by: 0.1).map { $0 }] {
            XCTAssertNil(PreparationFrameReader.ranges(times: times, frameDuration: step, duration: duration))
        }
        XCTAssertNil(PreparationFrameReader.ranges(times: [1], frameDuration: .zero, duration: duration))
    }
}
