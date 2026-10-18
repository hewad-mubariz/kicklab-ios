import XCTest
import CoreML
@testable import kicklab

final class DetectorSelectionTests: XCTestCase {
    @MainActor
    func testNormalModelBundlesTheRFSmallFP16Export() throws {
        let resource = BallDetector.configuredResourceName
        XCTAssertEqual(resource, RFSmallModel.fp16.rawValue)
        let url = try XCTUnwrap(Bundle.main.url(forResource: resource, withExtension: "mlmodelc"))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        configuration.functionName = RFDeviceProfile.current.functionName
        let model = try MLModel(contentsOf: url, configuration: configuration)
        XCTAssertNoThrow(try RFSegBridge.validate(model.modelDescription, outputType: .float16))
        XCTAssertEqual(BallDetector.ballThreshold(for: resource), 0.40)
    }

    @MainActor
    func testRFExportsMatchExplicitPrecisionContracts() throws {
        for variant in [RFSmallModel.fp16] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: variant.rawValue, withExtension: "mlmodelc"))
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            config.functionName = RFDeviceProfile.current.functionName
            let model = try MLModel(contentsOf: url, configuration: config)
            XCTAssertNoThrow(try RFSegBridge.validate(model.modelDescription, outputType: variant.outputType))
            XCTAssertThrowsError(try RFSegBridge.validate(model.modelDescription,
                outputType: variant == .fp16 ? .float32 : .float16))
            XCTAssertEqual(BallDetector.ballThreshold(for: variant.rawValue), 0.40)
            XCTAssertEqual(variant.foregroundComputeUnits, .cpuAndGPU)
        }
        XCTAssertNotEqual(RFSmallModel.fp16.pipelineIdentity, RFSmallModel.fp32.pipelineIdentity)
    }

    func testStandaloneStudiesCanExplicitlyLookUpOtherModels() {
        XCTAssertEqual(BallDetector.resourceName(for: []), "RFDETRSmallRecovery040FP16")
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
