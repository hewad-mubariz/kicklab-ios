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
            XCTAssertEqual(composition.sourceTrackIDForFrameTiming,
                override == nil ? track.trackID : kCMPersistentTrackID_Invalid)
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

    private func gappedCapture(in folder: URL, fps: Int) async throws -> URL {
        let url = folder.appendingPathComponent("gapped-\(fps).mp4")
        let movie = try PreviewMovie(url: url, size: CGSize(width: 64, height: 96), frameRate: Double(fps))
        let pixels = try movie.buffer()
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 80,
            CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        // Reproduce the real capture: one frame, a long startup gap, then full-rate footage.
        try await movie.append(pixels, time: .zero)
        for index in 0..<24 {
            try await movie.append(pixels, time: CMTime(value: Int64(fps * 7 + index), timescale: Int32(fps)))
        }
        try await movie.finish(duration: CMTime(value: Int64(fps * 7 + 24), timescale: Int32(fps)))
        return url
    }

    private func frameTimes(_ url: URL, composed: Bool) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if composed {
            let value = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: settings)
            value.videoComposition = try await EffectVideoGeometry.composition(track: video,
                duration: asset.load(.duration), shortEdge: 64)
            output = value
        } else { output = AVAssetReaderTrackOutput(track: video, outputSettings: settings) }
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times = [Double]()
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        XCTAssertEqual(reader.status, .completed)
        return times
    }

    func testSourceTimingPreservesEveryFrameAfterCaptureGapAt60And120FPS() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for fps in [60, 120] {
            let source = try await gappedCapture(in: folder, fps: fps)
            let raw = try await frameTimes(source, composed: false)
            let composed = try await frameTimes(source, composed: true)
            XCTAssertEqual(raw.count, 25)
            XCTAssertEqual(composed, raw, "A startup gap must not lower the cadence of the remaining footage")
        }
    }

    func testCustomizedExportRetainsGappedSourceTimestamps() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for fps in [60, 120] {
            let source = try await gappedCapture(in: folder, fps: fps)
            // A skin selects the actual customization decoder; no detector is needed to test its clock.
            let exported = try await BallStyleBurnIn.render(source: source, track: [], style: .none,
                skin: .pearl, intensity: 0, shortEdge: 64)
            defer { try? FileManager.default.removeItem(at: exported) }
            XCTAssertEqual(exported.pathExtension, fps > 60 ? "mov" : "mp4")
            let expected = try await frameTimes(source, composed: false)
            let actual = try await frameTimes(exported, composed: false)
            XCTAssertEqual(actual.count, expected.count)
            for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: 1.0 / 60_000) }
        }
    }
}
