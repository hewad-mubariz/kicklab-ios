#if DEBUG
import AVFoundation
import UIKit
import XCTest
@testable import kicklab

/// Opt-in device measurements. Inputs are copied into the app's Documents/
/// ResourceValidation directory; ordinary test runs skip these long operations.
final class LiveResourceDeviceTests: XCTestCase {
    private func selectedFolder() throws -> URL {
        let configuration = URL.documentsDirectory.appendingPathComponent("ResourceValidation/endurance-source.txt")
        let relative = (try? String(contentsOf: configuration, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipUnless(relative.hasPrefix("FinalValidation/"), "No device resource benchmark selected")
        return URL.documentsDirectory.appendingPathComponent(relative)
    }

    @MainActor
    func testThirtySecondLiveResourceCapture() async throws {
        _ = try selectedFolder()
        try XCTSkipUnless(AVCaptureDevice.default(for: .video) != nil, "Requires a physical camera")
        func wait(_ condition: () -> Bool, seconds: Double = 60) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(condition(), "Camera validation timed out")
            if !condition() { throw NSError(domain: "ResourceValidation", code: 2) }
        }
        let camera = CameraSession()
        let coordinator = FinalTestCoordinator.shared
        defer { camera.stop() }
        camera.start()
        try await wait { camera.canRecord }
        coordinator.arm(30)
        camera.startRecording()
        try await wait { camera.isRecording }
        try await wait({ !camera.isRecording && !camera.isFinishingRecording }, seconds: 50)
        XCTAssertNil(camera.recordingError)
        XCTAssertEqual(camera.capturePerformance.selectedFPS, 60)
        XCTAssertEqual(camera.capturePerformance.writerDrops, 0)
        XCTAssertGreaterThan(camera.capturePerformance.writtenFrames, 1700)
        XCTAssertGreaterThan(camera.capturePerformance.analysedFrames, 100)
        XCTAssertLessThan(camera.capturePerformance.analysedFrames, 930)
        try await wait { coordinator.report?.stages["video"]?.status != "running" }
        XCTAssertEqual(coordinator.report?.stages["recording"]?.status, "completed")
        XCTAssertEqual(coordinator.report?.stages["video"]?.status, "completed")
        coordinator.saveNotes("Automated resource-policy capture. No human juggling accuracy or long-duration thermal verdict.", expected: "")
        let folder = try XCTUnwrap(coordinator.folder)
        try folder.lastPathComponent.write(to: URL.documentsDirectory.appendingPathComponent("ResourceValidation/live-run.txt"),
            atomically: true, encoding: .utf8)
    }

    @MainActor
    func testRetainedVideoDownload() async throws {
        let root = URL.documentsDirectory.appendingPathComponent("ResourceValidation")
        let folder = try selectedFolder()
        let source = folder.appendingPathComponent("source.mov")
        let rows = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: folder.appendingPathComponent("live-touches.json")))
        let touches = rows.map { RecordedTouch(index: Int($0[1]), time: $0[0], x: $0[2], y: $0[3]) }
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let count = touches.count
        let summary = SessionSummary.make(touches: count, duration: duration, bestCombo: count, personalBest: count,
            videoURL: source, touchesMarked: touches, track: [])
        var overlays = ExportOverlaySettings()
        overlays.counter.enabled = true; overlays.counter.style = .normal
        overlays.showTimer = true; overlays.graph.enabled = false
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let start = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Double]] = []
        let downloader = ReplayDownloader()
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                let saving: Double = downloader.phase == .saving ? 1 : 0
                samples.append(["seconds": ProcessInfo.processInfo.systemUptime - start,
                    "memory_mib": DetectorPerformance.memoryMB(),
                    "progress": downloader.progress, "saving": saving,
                    "thermal": Double(ProcessInfo.processInfo.thermalState.rawValue)])
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        await downloader.download(summary: summary, edit: SessionEditState(style: .none, intensity: 0),
            overlays: overlays, sceneModel: StadiumPreviewModel(), preparation: SessionEffectsPreparation())
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        monitor.cancel(); await monitor.value
        XCTAssertEqual(downloader.phase, .saved)
        let url = try XCTUnwrap(downloader.savedURL)
        let destination = root.appendingPathComponent("endurance-after-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: url, to: destination)
        let output = AVURLAsset(url: destination)
        let outputDuration = try await output.load(.duration).seconds
        let outputTracks = try await output.loadTracks(withMediaType: .video)
        let outputTrack = try XCTUnwrap(outputTracks.first)
        let size = try await outputTrack.load(.naturalSize)
        let fps = try await outputTrack.load(.nominalFrameRate)
        let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).count
        let outputAudio = try await output.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(outputDuration, duration, accuracy: 0.1)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        XCTAssertEqual(Double(fps), 60, accuracy: 0.1)
        XCTAssertEqual(outputAudio, sourceAudio)
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let report: [String: Any] = ["elapsed_s": elapsed, "output_bytes": bytes, "output_file": destination.lastPathComponent, "duration_s": outputDuration,
            "count": count, "fps": fps, "audio_tracks": outputAudio, "samples": samples,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("export-result.json"))
    }

    func testRealRetainedMasksAreLosslessAndSmaller() throws {
        _ = try selectedFolder()
        let root = URL.documentsDirectory.appendingPathComponent("ResourceValidation")
        let fixture = root.appendingPathComponent("mask-fixture.plist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "No real mask fixture selected")
        let stored = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: fixture))
        XCTAssertTrue(StoredFrame.validated(stored))
        let frames = stored.map(\.frame)
        let packedBytes = frames.reduce(0) { $0 + ($1.ballMask?.storageByteCount ?? 0) }
        let rawBytes = frames.reduce(0) { $0 + ($1.ballMask.map { $0.width * $0.height } ?? 0) }
        let started = ProcessInfo.processInfo.systemUptime
        for frame in frames {
            if let mask = frame.ballMask {
                let expanded = mask.expanded()
                XCTAssertEqual(mask.alpha, expanded.alpha)
                XCTAssertEqual(expanded.compacted().alpha, mask.alpha)
                XCTAssertEqual(mask.rect, expanded.rect)
                XCTAssertEqual(mask.coverage(x: mask.rect.midX, y: mask.rect.midY),
                               expanded.coverage(x: mask.rect.midX, y: mask.rect.midY))
            }
        }
        XCTAssertLessThan(packedBytes, rawBytes / 3)
        let result: [String: Any] = ["frames": frames.count, "raw_mask_bytes": rawBytes,
            "retained_mask_bytes": packedBytes, "roundtrip_seconds": ProcessInfo.processInfo.systemUptime - started]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("masks-result.json"))
    }
}
#endif
