import AVFoundation
import XCTest
@testable import kicklab

/// Explicit experiment only: launch this test with --fasterrcnn. Normal app
/// launches and ordinary test runs continue using SSDLite.
final class FasterRCNNPhoneBenchmarkTests: XCTestCase {
    @MainActor
    func testBoundedRecordingBenchmark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.arguments.contains("--fasterrcnn"),
                          "Requires explicit experimental model selection")
        try XCTSkipUnless(AVCaptureDevice.default(for: .video) != nil, "Requires a phone camera")
        XCTAssertEqual(BallDetector.configuredResourceName, "KickLabFasterRCNN")
        let camera = CameraSession()
        defer { camera.stop() }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DetectorBenchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reportURL = folder.appendingPathComponent("fasterrcnn-optimized-phone.json")
        var rows: [[String: Any]] = []
        var report: [String: Any] = [
            "status": "starting", "variant": "FP16 features, 100 proposals, unchanged resolution",
            "memory_budget_mib": 400, "early_stop_mib": 900,
            "note": "Whole app under XCTest, sampled every 50 ms; not an instantaneous peak or sustained thermal test.",
        ]
        func save() throws {
            report["samples"] = rows
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        try save()
        camera.start()
        let readyDeadline = Date().addingTimeInterval(10)
        while !camera.isReady, Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(camera.isReady)
        guard camera.isReady else { return }
        report["preview_memory_mib"] = DetectorPerformance.memoryMB()
        XCTAssertEqual(camera.processedFrames, 0)
        camera.startRecording()
        let started = ProcessInfo.processInfo.systemUptime
        var recordingStart: Double?
        var peakMB = 0.0
        var stopReason = "duration_completed"
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            let now = ProcessInfo.processInfo.systemUptime
            let memory = DetectorPerformance.memoryMB()
            peakMB = max(peakMB, memory)
            if camera.isRecording, recordingStart == nil { recordingStart = now }
            rows.append([
                "elapsed_s": now - started, "memory_mib": memory,
                "processed_frames": camera.processedFrames, "recording": camera.isRecording,
                "inference_ms": camera.performance.inferenceMS,
                "detector_ms": camera.performance.totalMS, "fps": camera.performance.processedFPS,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            ])
            report["status"] = "running"
            try save()
            if memory > 900 { stopReason = "memory_guard"; break }
            if let error = camera.recordingError {
                report["error"] = error; stopReason = "recording_error"; break
            }
            if let since = recordingStart, now - since >= 8 { break }
            if now - started > 30 { stopReason = "startup_timeout"; break }
        } while true
        let processed = camera.processedFrames
        let csv = camera.performance.logURL
        camera.stop()
        let finishDeadline = Date().addingTimeInterval(10)
        while camera.isFinishingRecording, Date() < finishDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        report["status"] = "completed"
        report["stop_reason"] = stopReason
        report["peak_sampled_app_mib"] = peakMB
        report["within_400_mib"] = peakMB <= 400
        report["processed_frames"] = processed
        report["csv_file"] = csv?.lastPathComponent
        report["recording_finished"] = !camera.isFinishingRecording
        if let file = camera.recordingURL {
            report["video_duration_s"] = try await AVURLAsset(url: file).load(.duration).seconds
            try? FileManager.default.removeItem(at: file)
        }
        try save()
        print("FASTER_RCNN_PHONE_REPORT \(reportURL.path) peak=\(peakMB) MiB frames=\(processed) stop=\(stopReason)")
        XCTAssertGreaterThan(processed, 0, "No completed detections; inspect benchmark report")
        XCTAssertFalse(camera.isFinishingRecording)
    }
}
