import AVFoundation
import XCTest
@testable import kicklab

final class Capture60FPSTests: XCTestCase {
    func testSelectsSupported60FPSAndFallsBackWithoutChoosing4K() {
        typealias C = CaptureFrameRate.Candidate
        let options = [C(width: 3840, height: 2160, ranges: [1...120], standardPixelFormat: true),
                       C(width: 1280, height: 720, ranges: [1...30], standardPixelFormat: true),
                       C(width: 1920, height: 1080, ranges: [1...60], standardPixelFormat: true),
                       C(width: 1280, height: 720, ranges: [1...60], standardPixelFormat: true)]
        XCTAssertEqual(CaptureFrameRate.select(options)?.index, 3)
        XCTAssertEqual(CaptureFrameRate.select(options)?.fps, 60)
        XCTAssertEqual(CaptureFrameRate.select(Array(options.prefix(2)))?.index, 1)
        XCTAssertEqual(CaptureFrameRate.select(Array(options.prefix(2)))?.fps, 30)
        XCTAssertNil(CaptureFrameRate.select([options[0]]))
    }

    func testSixtyAndFractionalSixtyOfferEverySecondFrame() {
        for rate in [60.0, 59.94] {
            var buffer = LiveAnalysisBuffer<Int>()
            var processed = [Int]()
            for i in 0..<600 {
                if let frame = buffer.offer(i, at: 500 + Double(i) / rate) {
                    processed.append(frame)
                    XCTAssertNil(buffer.finish())
                }
            }
            XCTAssertEqual(processed, Array(stride(from: 0, to: 600, by: 2)))
            XCTAssertEqual(buffer.throttled, 300)
            XCTAssertEqual(buffer.replaced, 0)
        }
    }

    func testSlowAnalysisKeepsOnlyTheNewestPendingFrameAndCancelReleasesIt() {
        var buffer = LiveAnalysisBuffer<Int>()
        XCTAssertEqual(buffer.offer(0, at: 0), 0)
        for i in 1..<600 { XCTAssertNil(buffer.offer(i, at: Double(i) / 60)) }
        XCTAssertEqual(buffer.pending, 598)
        XCTAssertEqual(buffer.replaced, 298)
        XCTAssertEqual(buffer.finish(), 598)
        XCTAssertNil(buffer.pending)
        XCTAssertNil(buffer.finish())
        XCTAssertFalse(buffer.isRunning)
        XCTAssertEqual(buffer.offer(600, at: 10), 600)
        XCTAssertNil(buffer.offer(602, at: 10 + 2.0 / 60))
        buffer.cancelPending()
        XCTAssertNil(buffer.finish())
        XCTAssertFalse(buffer.isRunning)
        XCTAssertNil(buffer.offer(603, at: .nan))
    }

    func testSubsamplingPreservesThirtyFPSCounterInputsAndEvents() {
        let arc = [0.35,0.4,0.46,0.53,0.60,0.67,0.73,0.76,0.74,0.70,0.63,0.55,0.46,0.38,0.32]
        let reference = StreamingCounter(), sampled = StreamingCounter()
        let person = PersonBox(x: 0.5, y: 0.45, width: 0.8, height: 0.9)
        func push(_ counter: StreamingCounter, _ index: Int) {
            let time = Int(Double(index) / 30 * 1000)
            _ = counter.push(frameIndex: index, timestampMs: time,
                ball: BallObservation(frameIndex: index, timestampMs: time, x: 0.5, y: arc[index % arc.count],
                    width: 0.05, height: 0.03, confidence: 0.9), person: person)
        }
        var buffer = LiveAnalysisBuffer<Int>()
        for i in 0..<arc.count * 4 { push(reference, i) }
        for i in 0..<arc.count * 8 {
            if let frame = buffer.offer(i, at: Double(i) / 60) {
                push(sampled, frame / 2)
                XCTAssertNil(buffer.finish())
            }
        }
        reference.flush(); sampled.flush()
        XCTAssertGreaterThan(reference.count, 0)
        XCTAssertEqual(reference.count, sampled.count)
        XCTAssertEqual(reference.touches.map(\.timestampMs), sampled.touches.map(\.timestampMs))
    }

    @MainActor
    func testSixtyFPSMaskTrackAndGoldExportKeepSourceCadence() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "experimentalBallModel")
        defaults.set("motionModel", forKey: "experimentalBallModel")
        defer {
            if let previous { defaults.set(previous, forKey: "experimentalBallModel") }
            else { defaults.removeObject(forKey: "experimentalBallModel") }
        }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-sixty", withExtension: "mov"))
        let frames = try await VideoAnalyzer.replayTrack(source: source)
        XCTAssertEqual(frames.count, 90)
        XCTAssertEqual(frames.filter { $0.ballMask != nil }.count, 90)
        let visual = BallEffectTrack(frames: frames)
        for index in 0..<90 { XCTAssertNotNil(visual.mask(at: Double(index) / 60)) }
        let exported = try await BallStyleBurnIn.render(source: source, track: frames,
            style: .none, skin: .gold, intensity: 0.8, shortEdge: 720)
        defer { try? FileManager.default.removeItem(at: exported) }
        let asset = AVURLAsset(url: exported)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let fps = try await track.load(.nominalFrameRate)
        XCTAssertEqual(fps, 60, accuracy: 0.1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, 90)
        let destination = URL.documentsDirectory.appendingPathComponent("capture-sixty-gold.mp4")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: exported, to: destination)
        try JSONSerialization.data(withJSONObject: ["masks": frames.count, "export_frames": count,
            "export_fps": fps, "source_frames": 90], options: .prettyPrinted)
            .write(to: URL.documentsDirectory.appendingPathComponent("capture-sixty-export.json"))
    }

    @MainActor
    func testPhoneBothLensesRecordSixtyWhileAnalysisIsBoundedAndRestartIsClean() async throws {
        try XCTSkipUnless(AVCaptureDevice.default(for: .video) != nil, "Physical phone camera required")
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "experimentalBallModel")
        defaults.set("motionModel", forKey: "experimentalBallModel")
        defer {
            if let previous { defaults.set(previous, forKey: "experimentalBallModel") }
            else { defaults.removeObject(forKey: "experimentalBallModel") }
        }
        let camera = CameraSession()
        defer { camera.stop() }
        camera.start()
        try await waitFor { camera.isReady }
        var reports = [[String: Any]]()
        for lens in 0..<2 {
            if lens == 1 {
                camera.flipCamera()
                try await waitFor { camera.isReady && camera.cameraPosition == .front }
            }
            XCTAssertEqual(camera.capturePerformance.selectedFPS, 60, "This phone should support 60 fps on both wide-angle lenses")
            XCTAssertEqual(camera.performance.model, "Not loaded")
            let previewFrames = camera.processedFrames
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(camera.processedFrames, previewFrames)
            camera.startRecording()
            try await waitFor { camera.isRecording }
            var peakMemory = 0.0
            var thermal = Set<Int>()
            for _ in 0..<120 {
                try await Task.sleep(for: .milliseconds(100))
                peakMemory = max(peakMemory, DetectorPerformance.memoryMB())
                thermal.insert(ProcessInfo.processInfo.thermalState.rawValue)
            }
            camera.stopRecording()
            try await waitFor { !camera.isFinishingRecording }
            XCTAssertNil(camera.recordingError)
            XCTAssertEqual(camera.performance.model, "Not loaded")
            let source = try XCTUnwrap(camera.recordingURL)
            let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration).seconds
            let nominal = try await track.load(.nominalFrameRate)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var times = [Double]()
            while let sample = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if time.isFinite, CMSampleBufferGetImageBuffer(sample) != nil { times.append(time) }
            }
            XCTAssertEqual(reader.status, .completed)
            let stats = camera.capturePerformance
            let effective = Double(times.count) / duration
            XCTAssertGreaterThan(effective, 55)
            XCTAssertEqual(times.count, stats.writtenFrames)
            XCTAssertEqual(stats.writerDrops, 0)
            XCTAssertLessThanOrEqual(Double(stats.analysedFrames) / duration, 30.6)
            XCTAssertGreaterThan(stats.writtenFrames, stats.analysedFrames)
            XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
            XCTAssertLessThanOrEqual(stats.analysisOffered, Int(duration * 30.5) + 2)
            let configuration = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats))
            let destination = URL.documentsDirectory.appendingPathComponent("capture-60fps-\(lens == 0 ? "back" : "front").mov")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            let frameCount = camera.processedFrames
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(camera.processedFrames, frameCount)
            XCTAssertNil(camera.ballBox)
            reports.append(["lens": lens == 0 ? "back" : "front", "duration": duration,
                "nominal_fps": nominal, "decoded_frames": times.count, "effective_fps": effective,
                "live_analysis_fps": Double(stats.analysedFrames) / duration,
                "capture": configuration, "peak_sampled_memory_mib": peakMemory,
                "thermal_states": Array(thermal).sorted(), "video": destination.lastPathComponent])
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL.documentsDirectory.appendingPathComponent("capture-60fps-phone-tests.json"))
        }
        // A cancelled model startup cannot publish frames into a reopened preview.
        camera.startRecording()
        camera.stop()
        try await waitFor { !camera.isFinishingRecording }
        XCTAssertNil(camera.recordingURL)
        XCTAssertEqual(camera.processedFrames, 0)
        camera.start()
        try await waitFor { camera.isReady }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(camera.isRecording)
        XCTAssertEqual(camera.performance.model, "Not loaded")
        XCTAssertEqual(camera.processedFrames, 0)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        if !condition() { throw NSError(domain: "Capture60FPSTimeout", code: 1) }
    }
}
