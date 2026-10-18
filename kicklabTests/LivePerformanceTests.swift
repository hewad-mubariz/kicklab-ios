import XCTest
@testable import kicklab

final class LivePerformanceTests: XCTestCase {
    func testStageTotalsIncludeContactStallsWithoutDoubleCountingCumulativePoseRequests() {
        var totals = LivePerformanceSummary()
        XCTAssertEqual(totals.meanFrameMS, 0)
        totals.observe(.init(totalMS: 20, motionMS: 1, contactBufferMS: 2, counterMS: 3,
            poseRequests: 2, handPoseRequests: 1, poseCacheHits: 1), inference: 10, preprocessing: 2, detector: 13)
        totals.observe(.init(totalMS: 140, motionMS: 2, contactBufferMS: 1, counterMS: 120,
            poseRequests: 8, handPoseRequests: 1, poseCacheHits: 5), inference: 10, preprocessing: 2, detector: 13)
        XCTAssertEqual(totals.frames, 2)
        XCTAssertEqual(totals.meanFrameMS, 80)
        XCTAssertEqual(totals.maxFrameMS, 140)
        XCTAssertEqual(totals.framesOver33MS, 1)
        XCTAssertEqual(totals.inferenceMS, 20)
        XCTAssertEqual(totals.detectorMS, 26)
        XCTAssertEqual(totals.counterMS, 123)
        XCTAssertEqual(totals.poseRequests, 8)
        XCTAssertEqual(totals.handPoseRequests, 1)
        XCTAssertEqual(totals.poseCacheHits, 5)
    }
}
