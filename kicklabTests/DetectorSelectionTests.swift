import XCTest
@testable import kicklab

final class DetectorSelectionTests: XCTestCase {
    func testNormalLaunchRetainsSSDLiteAndExplicitOverrideWins() {
        XCTAssertEqual(BallDetector.resourceName(for: []), "KickLabDetector")
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolox-finetuned"]),
                       "KickLabYOLOXTinyFineTuned")
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolox"]), "KickLabYOLOXTiny")
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolox-roi"]), "KickLabYOLOXTinyFineTuned")
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolox-roi", "--ssdlite"]), "KickLabDetector")
        XCTAssertEqual(BallDetector.resourceName(for: ["--yolox-finetuned", "--ssdlite"]),
                       "KickLabDetector")
    }

    func testCalibratedThresholdAppliesOnlyToTrainedCandidate() {
        XCTAssertEqual(BallDetector.ballThreshold(for: "KickLabYOLOXTinyFineTuned"), 0.10)
        XCTAssertEqual(BallDetector.ballThreshold(for: "KickLabYOLOXTiny"), 0.05)
        XCTAssertEqual(BallDetector.ballThreshold(for: "KickLabDetector"), 0.05)
        XCTAssertEqual(BallDetector.ballThreshold(for: "KickLabFasterRCNN"), 0.40)
    }
}
