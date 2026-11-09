import XCTest
@testable import kicklab

final class LivePerformanceTests: XCTestCase {
    func testPoseSnapshotsStayCumulativeAndAreNotAddedTwice() throws {
        var totals = LivePerformanceSummary()
        let first = ShoePosePerformance(enabled: true, calls: 1, totalMS: 40, loadMS: 30, inferenceMS: 10)
        let second = ShoePosePerformance(enabled: true, calls: 3, totalMS: 60, loadMS: 30, inferenceMS: 30)
        for pose in [first, second] {
            totals.observe(.init(totalMS: 100, motionMS: 0, contactBufferMS: 60, counterMS: 10,
                poseRequests: 0, handPoseRequests: 0, poseCacheHits: 0, shoePose: pose),
                inference: 20, preprocessing: 0, detector: 20)
        }
        XCTAssertEqual(totals.totalMS, 200)
        XCTAssertEqual(totals.shoePose?.calls, 3)
        XCTAssertEqual(totals.shoePose?.totalMS, 60)
        XCTAssertEqual(totals.shoePose?.meanInferenceMS, 10)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(totals)) as! [String: Any]
        legacy.removeValue(forKey: "shoePose")
        let restored = try JSONDecoder().decode(LivePerformanceSummary.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.shoePose)
        XCTAssertEqual(restored.totalMS, 200)
    }

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
