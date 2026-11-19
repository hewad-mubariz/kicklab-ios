import AVFoundation
import CryptoKit
import MediaPipeTasksVision
import UIKit
import XCTest
@testable import kicklab

final class CounterV2IntegrationTests: XCTestCase {
    func testQualifiedModelIdentityAndCounterConfiguration() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: CounterV2Policy.poseModelName, withExtension: "task"))
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1")
        XCTAssertFalse(CounterV2Policy.singlePersonControl)
        XCTAssertTrue(CounterV2Policy.extendedContacts)
        var original = CounterConfig()
        original.touchCooldownMs = 321
        let updated = CounterV2Policy.configuration(original)
        XCTAssertEqual(updated.touchCooldownMs, 321)
        XCTAssertEqual(updated.recoversShortObservedFootRebound, true)
        XCTAssertEqual(updated.requiresResolvedEdgeFootContact, true)
        XCTAssertNil(original.recoversShortObservedFootRebound)
        XCTAssertNil(original.requiresResolvedEdgeFootContact)
        XCTAssertFalse(RFFramePredictionReuse.persistenceEnabled)
        XCTAssertFalse(ShotReplayReuse.enabled)
    }

    /// Real graph inference catches missing static registrations that a successful link misses.
    /// Match the production image-mode / two-pose / CPU contract, including a blank exposure.
    func testFullGraphProducesFeetAfterBlankImageAndFreshProviderWarmsUp() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let asset = AVURLAsset(url: source)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let visible = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, CVPixelBufferGetWidth(visible), CVPixelBufferGetHeight(visible),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made), kCVReturnSuccess)
        let blank = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(blank, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(blank))
        memset(bytes, 0, CVPixelBufferGetBytesPerRow(blank) * CVPixelBufferGetHeight(blank))
        CVPixelBufferUnlockBaseAddress(blank, [])
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = try XCTUnwrap(Bundle.main.path(forResource: CounterV2Policy.poseModelName, ofType: "task"))
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.numPoses = 2
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.shouldOutputSegmentationMasks = false
        let model = try PoseLandmarker(options: options)
        for pixels in [visible, blank, visible] {
            let result = try model.detect(image: MPImage(pixelBuffer: pixels, orientation: .up))
            if pixels === blank { XCTAssertTrue(result.landmarks.isEmpty); continue }
            let pose = try XCTUnwrap(result.landmarks.first)
            XCTAssertEqual(pose.count, 33)
            for index in [27, 28, 31, 32] {
                XCTAssertTrue(pose[index].x.isFinite && pose[index].y.isFinite)
                XCTAssertNotNil(pose[index].visibility)
                XCTAssertNotNil(pose[index].presence)
            }
        }
        let observations = ContactObservationStore()
        let native = JugglingContactVerifier(observations: observations)
        let provider = try LiveToeVerifier(base: native, observations: observations)
        provider.bind(to: native)
        XCTAssertNil(provider.error)
        XCTAssertEqual(provider.requests, 0, "Warmup must not claim a contact observation")
        XCTAssertGreaterThan(provider.warmUpSeconds, 0)
        provider.reset()
        XCTAssertNil(provider.footEvidence(at: 0), "A missing player/frame must not supply toe proof")
    }
}
