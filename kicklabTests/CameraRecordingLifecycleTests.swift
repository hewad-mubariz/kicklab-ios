import AVFoundation
import XCTest
@testable import kicklab

/// Device integration checks: exercise real capture callbacks, model loading
/// and file writing, rather than asserting a stand-alone state flag.
final class CameraRecordingLifecycleTests: XCTestCase {
    @MainActor
    func testPreviewRecordStopAndReopen() async throws {
        try requireCamera()
        let camera = CameraSession()
        defer { camera.stop() }
        let logsBefore = benchmarkFiles()
        camera.start()
        try await waitFor { camera.isReady }
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
        try await waitFor { camera.isReady }
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
        let logsBefore = benchmarkFiles()
        camera.start()
        camera.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(camera.isReady)
        XCTAssertEqual(camera.performance.model, "Not loaded")

        camera.start()
        try await waitFor { camera.isReady }
        camera.startRecording()
        camera.stop() // Cancel before the queued model load can produce frames.
        try await waitFor { !camera.isFinishingRecording }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(camera.isRecording)
        XCTAssertFalse(camera.isPreparingRecording)
        XCTAssertFalse(camera.isReady)
        XCTAssertEqual(camera.processedFrames, 0)
        XCTAssertNil(camera.recordingURL)
        XCTAssertEqual(camera.performance.model, "Not loaded")
        XCTAssertEqual(benchmarkFiles(), logsBefore)
    }

    @MainActor
    private func requireCamera() throws {
        try XCTSkipUnless(AVCaptureDevice.default(for: .video) != nil, "Requires a physical camera")
        XCTAssertEqual(BallDetector.configuredResourceName, "KickLabYOLO26MotionSegmentation")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 12) async throws {
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
