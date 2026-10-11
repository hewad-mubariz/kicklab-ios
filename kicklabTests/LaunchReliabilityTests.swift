import AVFoundation
import XCTest
@testable import kicklab

@MainActor
final class LaunchReliabilityTests: XCTestCase {
    func testReadinessCancellationStopsPollingAndTimeoutIsBounded() async throws {
        var polls = 0
        let task = Task {
            try await MediaReadiness.wait { polls += 1; return false }
        }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        do { try await task.value; XCTFail("Cancelled wait completed") }
        catch is CancellationError { }
        let finalPolls = polls
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(polls, finalPolls)
        XCTAssertLessThan(polls, 5)
        do {
            try await MediaReadiness.wait(timeout: .milliseconds(50)) { false }
            XCTFail("Unknown player did not time out")
        } catch MediaReadiness.Failure.timedOut { }
    }

    func testReadinessFailurePropagatesInsteadOfWaiting() async throws {
        do {
            try await MediaReadiness.wait { throw MediaReadiness.Failure.unavailable }
            XCTFail("Player failure ignored")
        } catch MediaReadiness.Failure.unavailable { }
    }

    func testVideoValidationAcceptsLongSessionsAndRejectsInvalidDuration() throws {
        for duration in [49.0, 120, 300, 600, 3_600] {
            try VideoSafetyPolicy.validate(duration: duration)
        }
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertThrowsError(try VideoSafetyPolicy.validate(duration: duration))
        }
    }

    func testStorageReserveStillProtectsRecordingAndExport() throws {
        XCTAssertThrowsError(try VideoSafetyPolicy.requireSpace(bytes: 1, available: VideoSafetyPolicy.storageReserve))
        try VideoSafetyPolicy.requireSpace(bytes: 1, available: VideoSafetyPolicy.storageReserve + 1)
    }

    func testBothExportersUseTheSameHighFrameRateFormat() async throws {
        for fps in [Float(30), 60] { XCTAssertEqual(VideoExportFormat.fileType(fps: fps), .mp4) }
        for fps in [Float(120), 240] { XCTAssertEqual(VideoExportFormat.fileType(fps: fps), .mov) }
        XCTAssertEqual(VideoExportFormat.playbackIntent().identifier, .quickTimeMetadataFullFrameRatePlaybackIntent)
        let intent = try await VideoExportFormat.playbackIntent().load(.numberValue)
        XCTAssertEqual(intent, 1)
    }

    func testWriterStartupFailureIsTerminalAndNextRecordingCanStart() async throws {
        var fail = true
        let recorder = Recorder(beginWriting: { fail ? false : $0.startWriting() })
        let pixels = try pixelBuffer()
        try recorder.start(width: 64, height: 64)
        XCTAssertThrowsError(try recorder.append(pixels, at: .zero))
        let failed = await stop(recorder)
        if case .success = failed { XCTFail("Failed writer reported a video") }
        XCTAssertFalse(recorder.isRecording)
        fail = false
        try recorder.start(width: 64, height: 64)
        try await append(pixels, to: recorder, frame: 0)
        let saved = try await stop(recorder).get()
        defer { try? FileManager.default.removeItem(at: saved) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testAppendFailureAfterGoodFramesIsNotBackpressure() async throws {
        var fail = false
        let recorder = Recorder(appendFrame: { fail ? false : $0.append($1, withPresentationTime: $2) })
        let pixels = try pixelBuffer()
        try recorder.start(width: 64, height: 64)
        for frame in 0..<3 { try await append(pixels, to: recorder, frame: frame) }
        XCTAssertEqual(recorder.writtenFrames, 3)
        fail = true
        do { try await append(pixels, to: recorder, frame: 3); XCTFail("Append failure ignored") }
        catch Recorder.Failure.append { }
        let saved = await stop(recorder)
        if case .success(let url) = saved { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(recorder.isRecording)
    }

    func testInterruptedJobJournalKeepsOnlyUnfinishedJobsAcrossRestart() throws {
        let suite = "launch-reliability-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = VideoJobJournal(defaults: defaults)
        journal.begin("first", title: "Saving replay")
        journal.begin("second", title: "Importing video")
        journal.finish("first")
        let restored = VideoJobJournal(defaults: defaults)
        XCTAssertEqual(restored.consumeInterruptedCount(), 1)
        XCTAssertEqual(restored.consumeInterruptedCount(), 0)
    }

    func testExportCleanupKeepsOriginalsRecentExportsAndUnrelatedFiles() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["juggledude-edited-old.mp4", "power-shot-recent.mov", "juggledude-run-original.mov", "unrelated.mp4"]
        for name in names { try Data([1]).write(to: folder.appendingPathComponent(name)) }
        let old = Date().addingTimeInterval(-90_000)
        for name in [names[0], names[2], names[3]] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        try VideoSafetyPolicy.cleanExpiredExports(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(names[0]).path))
        for name in names.dropFirst() { XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)) }
    }

    func testBurnInCancellationDrainsWorkerBeforeRetryAndDoesNotReuseOldOutput() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let movie = try PreviewMovie(url: source, size: CGSize(width: 64, height: 64))
        for frame in 0..<6 { try await movie.append(pixelBuffer(), time: CMTime(value: Int64(frame), timescale: 30)) }
        try await movie.finish(duration: CMTime(value: 6, timescale: 30))
        let burnIn = BallStyleBurnIn()
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false)
        func start() {
            VideoWorkExecution.$lease.withValue(lease) {
                burnIn.export(source: source, track: [], style: .none, intensity: 0)
            }
        }
        start()
        await burnIn.cancelAndWait()
        XCTAssertFalse(burnIn.isExporting)
        XCTAssertNil(burnIn.outputURL)
        start()
        try await MediaReadiness.wait { !burnIn.isExporting }
        let first = try XCTUnwrap(burnIn.outputURL, burnIn.status)
        defer { try? FileManager.default.removeItem(at: first) }
        start()
        try await MediaReadiness.wait { !burnIn.isExporting }
        let second = try XCTUnwrap(burnIn.outputURL, burnIn.status)
        defer { try? FileManager.default.removeItem(at: second) }
        XCTAssertNotEqual(first, second, "Each explicit request must use current source and track inputs")
        let duration = try await AVURLAsset(url: second).load(.duration).seconds
        XCTAssertEqual(duration, 0.2, accuracy: 0.01)
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
    private func append(_ pixels: CVPixelBuffer, to recorder: Recorder, frame: Int) async throws {
        for _ in 0..<100 {
            if try recorder.append(pixels, at: CMTime(value: Int64(frame), timescale: 30)) != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Writer never became ready")
    }
    private func stop(_ recorder: Recorder) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume(returning: $0) } }
    }
}
