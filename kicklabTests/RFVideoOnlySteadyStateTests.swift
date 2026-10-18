import AVFoundation
import XCTest
@testable import kicklab

final class RFVideoOnlySteadyStateTests: XCTestCase {
    @MainActor func testTenSecondRecordingOnBothLenses() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw XCTSkip("Camera permission required") }
        let folder = URL.documentsDirectory.appendingPathComponent("RFValidation-video-only-steady")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let camera = CameraSession(pipeline: .videoOnly); defer { camera.stop() }
        func wait(_ condition: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime+45
            while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(condition()); if !condition() { throw NSError(domain: "Camera readiness timeout", code: 1) }
        }
        var rows = [[String: Any]]()
        camera.start(); try await wait { camera.canRecord }
        for lens in [AVCaptureDevice.Position.back, .front] {
            if camera.cameraPosition != lens { camera.flipCamera(); try await wait { camera.canRecord && camera.cameraPosition == lens } }
            camera.startRecording(); try await wait { camera.isRecording && camera.recordingElapsed >= 10 }
            camera.stop(); try await wait { !camera.isFinishingRecording }
            XCTAssertNil(camera.recordingError)
            let source = try XCTUnwrap(camera.recordingURL)
            let name = lens == .back ? "back.mov" : "front.mov"
            let target = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: target)
            let asset = AVURLAsset(url: target)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let fps = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration).seconds
            let stats = camera.capturePerformance
            XCTAssertGreaterThanOrEqual(duration, 10)
            XCTAssertEqual(fps, 60, accuracy: 1)
            XCTAssertEqual(stats.writerDrops, 0)
            XCTAssertEqual(stats.analysisOffered, 0)
            XCTAssertEqual(camera.processedFrames, 0)
            rows.append(["lens": name, "duration": duration, "fps": fps, "frames": stats.writtenFrames,
                         "capture_drops": stats.captureDrops, "writer_drops": stats.writerDrops, "analysis_offered": stats.analysisOffered])
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("results.json"))
            camera.clearRecording(); camera.start(); try await wait { camera.canRecord }
        }
    }
}
