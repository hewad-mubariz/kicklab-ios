import AVFoundation
import CoreImage
import CoreML
import XCTest
@testable import kicklab

final class RFDeviceProfileTests: XCTestCase {
    func testMarketingBoundaryUsesExactIdentifiersIncludingProAndSE() {
        for identifier in ["iPhone12,5", "iPhone13,3", "iPhone14,5", "iPhone14,4",
                           "iPhone14,2", "iPhone14,3", "iPhone12,8", "iPhone14,6"] {
            XCTAssertEqual(RFDeviceProfile.resolution(for: identifier), .compact, identifier)
        }
        for identifier in ["iPhone14,7", "iPhone14,8", "iPhone15,2", "iPhone15,3",
                           "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2",
                           "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4", "iPhone17,5",
                           "iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4", "iPhone18,5",
                           "iPhone19,2", "iPhone19,3", "iPhone19,7"] {
            XCTAssertEqual(RFDeviceProfile.resolution(for: identifier), .detailed, identifier)
        }
        for identifier in ["", "unknown", "iPhone99,1", "iPhone14,99", "iPad16,1", "Hewad’s iPhone 14"] {
            XCTAssertEqual(RFDeviceProfile.resolution(for: identifier), .compact, identifier)
        }
    }

    func testResolutionNamespacesCannotReuseOtherSizeOrLegacyResults() throws {
        let name = "RFProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let compact = SessionAnalysisStore.pipelineOptions(arguments: [], defaults: defaults, resolution: .compact)
        let detailed = SessionAnalysisStore.pipelineOptions(arguments: [], defaults: defaults, resolution: .detailed)
        XCTAssertNotEqual(compact, detailed)
        XCTAssertTrue(compact.contains("function=rf288|rgb288"))
        XCTAssertTrue(detailed.contains("function=rf384|rgb384"))
        XCTAssertFalse(compact.contains("rgb288-fullapp-v1"))
        XCTAssertFalse(detailed.contains("rgb384-fp16-gpu-v1"))
        XCTAssertNotEqual(RFSmallModel.fp16.pipelineIdentity, RFSmallModel.fp32.pipelineIdentity)
        for resolution in RFInputResolution.allCases {
            let a = SessionAnalysisStore.pipelineOptions(arguments: [], defaults: defaults, resolution: resolution)
            defaults.set("motion", forKey: "experimentalBallModel")
            let b = SessionAnalysisStore.pipelineOptions(arguments: ["--ssdlite"], defaults: defaults, resolution: resolution)
            XCTAssertEqual(a, b)
            #if DEBUG && TOUCH_COUNTING_DEBUG
            let study = SessionAnalysisStore.pipelineOptions(arguments: ["--rf-input-study", "RFTest288"], defaults: defaults, resolution: resolution)
            XCTAssertNotEqual(a, study)
            XCTAssertNotEqual(study, SessionAnalysisStore.pipelineOptions(arguments: ["--rf-input-study", "RFTest384"], defaults: defaults, resolution: resolution))
            #endif
        }
    }

    func testBothBundledSizesPassRuntimeContract() {
        XCTAssertTrue(RFSegBridge.supports(edge: 288))
        XCTAssertTrue(RFSegBridge.supports(edge: 384))
        XCTAssertFalse(RFSegBridge.supports(edge: 388))
        XCTAssertFalse(RFSegBridge.supports(edge: 0))
    }

    @MainActor func testAutomaticDeviceSelectionLoadsLiveAndSavedPaths() throws {
        let selected = RFDeviceProfile.current
        let expectations = ["iPhone12,5": 288, "iPhone18,2": 384]
        if let expected = expectations[RFDeviceProfile.hardwareIdentifier] {
            XCTAssertEqual(selected.rawValue, expected)
        }
        XCTAssertFalse(RFDeviceProfile.hardwareIdentifier.isEmpty)
        let worker = try RFWorker(resources: XCTUnwrap(Bundle.main.resourceURL))
        XCTAssertEqual(worker.model.configuration.functionName, selected.functionName)
        XCTAssertEqual(try RFSegBridge.validate(worker.model.modelDescription, outputType: .float16), selected.rawValue)
        let detector = try BallDetector()
        XCTAssertEqual(detector.modelInputSize, CGSize(width: selected.rawValue, height: selected.rawValue))
        XCTAssertTrue(detector.modelName.contains("· \(selected.rawValue) ·"))
        try detector.warmUp()
        let row: [String: Any] = ["hardware": RFDeviceProfile.hardwareIdentifier,
            "resolution": selected.rawValue, "function": worker.model.configuration.functionName ?? "missing",
            "live_compute": worker.computeDescription, "saved_compute": detector.modelComputeDescription,
            "policy": RFDeviceProfile.policyVersion, "cache_identity": RFSmallModel.fp16.pipelineIdentity,
            "automatic": true]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL.documentsDirectory.appendingPathComponent("RF-local-profile-selection.json"), options: .atomic)
        print("RF_PROFILE_SELECTION \(String(decoding: data, as: UTF8.self))")
    }

    @MainActor func testBothFunctionsPredictAndAgreeAcrossLiveAndSavedAdapters() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let reader = try AVAssetReader(asset: AVURLAsset(url: url))
        // This small fixture is bundled and its video track is immediately available.
        let track = try XCTUnwrap(reader.asset.tracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading()); defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let frame = PacedFrame(index: 0, time: 0, due: ProcessInfo.processInfo.systemUptime,
                               image: CIImage(cvPixelBuffer: pixels), pixels: pixels)
        for resolution in RFInputResolution.allCases {
            try autoreleasepool {
                let worker = try RFWorker(resources: XCTUnwrap(Bundle.main.resourceURL), resolution: resolution)
                XCTAssertEqual(worker.model.configuration.functionName, resolution.functionName)
                XCTAssertEqual(try RFSegBridge.validate(worker.model.modelDescription, outputType: .float16), resolution.rawValue)
                let reply = worker.infer(frame, hint: nil)
                XCTAssertNil(reply.error)
                let detector = try BallDetector(rfResolution: resolution)
                let found = try detector.detect(pixels, orientLandscapeAsPortrait: false)
                XCTAssertEqual(detector.modelInputSize.width, CGFloat(resolution.rawValue))
                XCTAssertEqual(found.ball != nil, reply.found.ball != nil)
                XCTAssertEqual(found.person != nil, reply.found.person != nil)
                if let a = found.ball, let b = reply.found.ball {
                    XCTAssertEqual(a.score, b.score, accuracy: 0.0001)
                    XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
                    XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
                    XCTAssertEqual(a.width, b.width, accuracy: 0.0001)
                    XCTAssertEqual(a.height, b.height, accuracy: 0.0001)
                }
                XCTAssertEqual(found.ballMask?.alpha, reply.found.ballMask?.alpha)
                XCTAssertEqual(found.ballMask?.rect, reply.found.ballMask?.rect)
                XCTAssertEqual(found.ballMask?.width, reply.found.ballMask?.width)
                XCTAssertEqual(found.ballMask?.height, reply.found.ballMask?.height)
            }
        }
    }
}
