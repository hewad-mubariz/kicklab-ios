import AVFoundation
import CoreImage
import CoreML
import Vision
import XCTest
@testable import kicklab

final class ModernVideoAPITests: XCTestCase {
    func testBackgroundVisionRequestsUseCPUAtEveryStage() throws {
        let requests: [VNRequest] = [
            VNDetectHumanBodyPoseRequest(),
            VNTranslationalImageRegistrationRequest(targetedCIImage: CIImage(color: .black)),
            VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)))
        ]
        requests[2].revision = VNTrackObjectRequestRevision1
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        try VideoWorkExecution.$lease.withValue(lease) {
            for request in requests {
                try VisionComputePolicy.configure(request)
                let stages = try request.supportedComputeStageDevices
                XCTAssertFalse(stages.isEmpty)
                for stage in stages.keys {
                    guard case .cpu? = request.computeDevice(for: stage) else {
                        return XCTFail("Background request must not choose GPU/Neural Engine: \(type(of: request)), \(stage)")
                    }
                }
            }
        }
    }

    func testForegroundVisionKeepsAutomaticDeviceSelection() throws {
        let request = VNDetectHumanBodyPoseRequest()
        try VisionComputePolicy.configure(request, cpuOnly: false)
        for stage in try request.supportedComputeStageDevices.keys {
            XCTAssertNil(request.computeDevice(for: stage))
        }
    }

    func testCompositionPreservesDurationOrientationAndSourceCadence() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-sixty", withExtension: "mov"))
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(transform).standardized
        for override in [nil, CMTime(value: 1, timescale: 30)] as [CMTime?] {
            let composition = try await EffectVideoGeometry.composition(track: track, duration: duration,
                shortEdge: 180, frameDuration: override)
            XCTAssertEqual(composition.frameDuration.seconds, override?.seconds ?? (1.0 / 60), accuracy: 0.000001)
            XCTAssertEqual(composition.renderSize.width / composition.renderSize.height,
                bounds.width / bounds.height, accuracy: 0.01)
            XCTAssertEqual(composition.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
            XCTAssertEqual(composition.instructions.first?.timeRange.duration, duration)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = composition
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(times.count, override == nil ? 90 : 45)
            XCTAssertEqual(try XCTUnwrap(times.last) + composition.frameDuration.seconds, duration.seconds, accuracy: 0.001)
        }
    }
}
