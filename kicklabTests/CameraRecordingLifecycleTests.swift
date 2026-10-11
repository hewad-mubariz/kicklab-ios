import AVFoundation
import XCTest
@testable import kicklab

/// Device integration checks: exercise real capture callbacks, model loading
/// and file writing, rather than asserting a stand-alone state flag.
final class CameraRecordingLifecycleTests: XCTestCase {
    @MainActor
    func testVideoOnlyRecordsBothLensesWithoutTrackingAndCanReopen() async throws {
        try requireCamera()
        let camera = CameraSession(pipeline: .videoOnly)
        defer { camera.stop() }
        let logsBefore = benchmarkFiles()
        camera.start()
        try await waitFor { camera.canRecord }
        for lens in [AVCaptureDevice.Position.back, .front] {
            if camera.cameraPosition != lens {
                camera.flipCamera()
                try await waitFor { camera.canRecord && camera.cameraPosition == lens }
            }
            XCTAssertFalse(camera.isTrackingReady)
            XCTAssertFalse(camera.isPreparingTracking)
            camera.startRecording()
            try await waitFor { camera.isRecording && camera.recordingElapsed >= 1 }
            camera.stop() // Same path used when the app goes to the background.
            try await waitFor { !camera.isFinishingRecording }
            XCTAssertNil(camera.recordingError)
            XCTAssertEqual(camera.processedFrames, 0)
            XCTAssertEqual(camera.capturePerformance.analysisOffered, 0)
            XCTAssertEqual(camera.performance.model, "Not loaded")
            XCTAssertTrue(camera.recordedTrack.isEmpty)
            XCTAssertTrue(camera.recordedTouches.isEmpty)
            XCTAssertEqual(camera.capturePerformance.selectedFPS, 60)
            XCTAssertGreaterThan(camera.capturePerformance.writtenFrames, 30)
            let file = try XCTUnwrap(camera.recordingURL)
            let asset = AVURLAsset(url: file)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let fps = try await track.load(.nominalFrameRate)
            XCTAssertEqual(min(size.width, size.height), 720)
            XCTAssertEqual(fps, 60, accuracy: 1)
            XCTAssertEqual(transform, .identity, "RotationCoordinator already orients the recorded pixels")
            try FileManager.default.removeItem(at: file)
            camera.clearRecording()
            camera.start()
            try await waitFor { camera.canRecord }
        }
        XCTAssertEqual(benchmarkFiles(), logsBefore, "Plain recording must not start any detector benchmark")
        camera.startRecording()
        camera.stop()
        try await waitFor { !camera.isFinishingRecording }
        XCTAssertFalse(camera.isPreparingRecording)
        XCTAssertNil(camera.recordingURL, "Cancelling pending startup must not open the previous video")
    }

    @MainActor
    func testPreviewRecordStopAndReopen() async throws {
        try requireCamera()
        let camera = CameraSession()
        defer { camera.stop() }
        let logsBefore = benchmarkFiles()
        camera.start()
        try await waitFor { camera.isReady && camera.isTrackingReady }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(camera.isRecording)
        XCTAssertEqual(camera.processedFrames, 0)
        XCTAssertEqual(camera.performance.model, "Not loaded")
        XCTAssertNil(camera.recordingURL)
        XCTAssertEqual(benchmarkFiles(), logsBefore, "Preview must not create inference logs")

        camera.startRecording()
        try await waitFor { camera.isRecording && camera.processedFrames >= 3 }
        XCTAssertEqual(camera.performance.model, "YOLO26-M revised masks + marginal retry")
        XCTAssertNil(camera.recordingError)
        XCTAssertGreaterThan(benchmarkFiles().count, logsBefore.count)

        camera.stopRecording()
        try await waitFor { !camera.isFinishingRecording }
        XCTAssertFalse(camera.isRecording)
        XCTAssertFalse(camera.isPreparingRecording)
        XCTAssertEqual(camera.performance.model, "Not loaded")
        XCTAssertEqual(camera.fps, 0)
        XCTAssertNil(camera.ballBox)
        XCTAssertNil(camera.personBox)
        let file = try XCTUnwrap(camera.recordingURL)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let duration = try await AVURLAsset(url: file).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        let framesAtStop = camera.processedFrames
        let finishedLog = try XCTUnwrap(camera.performance.logURL)
        let logAtStop = try Data(contentsOf: finishedLog)

        camera.stop()
        camera.start()
        try await waitFor { camera.isReady && camera.isTrackingReady }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(camera.isRecording)
        XCTAssertEqual(camera.processedFrames, framesAtStop)
        XCTAssertEqual(camera.performance.model, "Not loaded")
        XCTAssertEqual(try Data(contentsOf: finishedLog), logAtStop,
                       "Reopening must not resume inference or append metrics")

        // A second explicit press is the only way to restart the pipeline.
        camera.startRecording()
        try await waitFor { camera.isRecording && camera.processedFrames >= 3 }
        camera.stop()
        try await waitFor { !camera.isFinishingRecording }
        XCTAssertFalse(camera.isReady)
        XCTAssertEqual(camera.performance.model, "Not loaded")
        if let secondFile = camera.recordingURL { try? FileManager.default.removeItem(at: secondFile) }
    }

    @MainActor
    func testClosingCancelsPendingStartup() async throws {
        try requireCamera()
        let camera = CameraSession()
        defer { camera.stop() }
        camera.start()
        camera.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(camera.isReady)
        XCTAssertFalse(camera.isTrackingReady)
        XCTAssertFalse(camera.isPreparingTracking)
        XCTAssertEqual(camera.performance.model, "Not loaded")

        camera.start()
        try await waitFor { camera.isReady && camera.isTrackingReady }
        camera.startRecording()
        camera.stop() // Cancel before the queued writer startup can produce frames.
        try await waitFor { !camera.isFinishingRecording }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(camera.isRecording)
        XCTAssertFalse(camera.isPreparingRecording)
        XCTAssertFalse(camera.isReady)
        XCTAssertEqual(camera.processedFrames, 0)
        XCTAssertNil(camera.recordingURL)
        XCTAssertEqual(camera.performance.model, "Not loaded")
    }

    @MainActor
    func testWarmupCanBeCancelledAndLensSwitchKeepsPreparedTracking() async throws {
        try requireCamera()
        let camera = CameraSession()
        defer { camera.stop() }
        camera.start()
        try await waitFor { camera.isReady }
        camera.stop()
        XCTAssertFalse(camera.isTrackingReady)
        XCTAssertFalse(camera.isPreparingTracking)
        camera.start()
        try await waitFor { camera.isReady && camera.isTrackingReady }
        camera.flipCamera()
        XCTAssertTrue(camera.isTrackingReady, "Lens changes must not discard the prepared model")
        try await waitFor { camera.isReady && camera.cameraPosition == .front }
        XCTAssertFalse(camera.isPreparingTracking)
        XCTAssertFalse(camera.isRecording)
        XCTAssertEqual(camera.processedFrames, 0)
        XCTAssertNil(camera.recordingURL)
    }

    @MainActor
    private func requireCamera() throws {
        try XCTSkipUnless(AVCaptureDevice.default(for: .video) != nil, "Requires a physical camera")
        XCTAssertEqual(BallDetector.configuredResourceName, "KickLabYOLO26MotionSegmentation")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "Timed out waiting for capture state")
        if !condition() { throw NSError(domain: "CameraRecordingLifecycleTests", code: 1) }
    }

    private func benchmarkFiles() -> Set<URL> {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("DetectorBenchmarks")
        return Set((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)) ?? [])
    }
}
