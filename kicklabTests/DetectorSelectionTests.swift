import XCTest
import CoreML
@testable import kicklab

final class DetectorSelectionTests: XCTestCase {
    @MainActor
    func testNormalModelBundlesTheValidatedMaskExport() throws {
        let resource = BallDetector.configuredResourceName
        let url = try XCTUnwrap(Bundle.main.url(forResource: resource, withExtension: "mlmodelc"))
        let model = try MLModel(contentsOf: url)
        let metadata = try XCTUnwrap(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
        XCTAssertEqual(metadata["precision"], "p3_features_fp32")
        XCTAssertEqual(Double(metadata["ball_threshold"] ?? ""), 0.30)
        XCTAssertNotNil(model.modelDescription.outputDescriptionsByName["mask_prototypes"])
        XCTAssertNotNil(model.modelDescription.outputDescriptionsByName["mask_coefficients"])
    }

    func testStandaloneStudiesCanExplicitlyLookUpOtherModels() {
        XCTAssertEqual(BallDetector.resourceName(for: []), "KickLabYOLO26MotionSegmentation")
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
