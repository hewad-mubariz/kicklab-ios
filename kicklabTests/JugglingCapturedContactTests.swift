import AVFoundation
import XCTest
@testable import kicklab

/// Explicit local development replay: real saved pixels + captured observation
/// cadence. It does not reproduce missing live camera offsets or thermal load.
final class JugglingCapturedContactTests: XCTestCase {
    @MainActor
    func testCapturedContactsOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical-device Vision pose and the local 34DD recording")
        #else
        let folder = URL.documentsDirectory.appendingPathComponent("ContactCountValidation")
        let source = folder.appendingPathComponent("source.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "Requires local 34DD source and captured rows")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("rows.json"))) as! [String: Any]
        let rows = raw["rows"] as! [[String: Any]]
        let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("labels.json"))) as! [String: Any]
        let expected = (labels["events"] as! [[String: Any]]).filter { $0["counts"] as? Bool == true }.map { $0["time_s"] as! Double }
        let asset = AVURLAsset(url: source), track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: track, duration: asset.load(.duration), shortEdge: 720)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let verifier = JugglingContactVerifier()
        verifier.warmUp()
        XCTAssertNil(verifier.lastError)
        var checks: [[String: Any]] = []
        let counter = StreamingCounter(rejectsHandContact: { frame in
            let rejected = verifier.rejectsHandContact(at: frame)
            checks.append(["frame": frame, "rejected": rejected, "ms": verifier.lastCheckMS])
            return rejected
        }, recordTrace: true)
        let heldFrame = rows.min { abs(($0["time"] as! Double) - 2.833) < abs(($1["time"] as! Double) - 2.833) }!["frame"] as! Int
        var heldVerified = false, rowIndex = 0, sourceIndex = 0
        var bufferMS = 0.0
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            defer { sourceIndex += 1 }
            guard rowIndex < rows.count else { continue }
            let row = rows[rowIndex]
            guard sourceIndex == row["source_frame"] as! Int else { continue }
            autoreleasepool {
                let frame = row["frame"] as! Int, ms = Int((row["time"] as! Double) * 1000)
                let pixels = CMSampleBufferGetImageBuffer(sample)!
                let ball = (row["ball"] as? [Double]).map { Detection(score: $0[0], x: $0[1], y: $0[2], width: $0[3], height: $0[4]) }
                let person = (row["person"] as? [Double]).map { PersonBox(x: $0[1], y: $0[2], width: $0[3], height: $0[4]) }
                let start = ProcessInfo.processInfo.systemUptime
                verifier.store(pixels, frameIndex: frame, timestampMs: ms, ball: ball, orientLandscapeAsPortrait: false)
                bufferMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
                if frame == heldFrame + 3 { heldVerified = verifier.rejectsHandContact(at: heldFrame) }
                let observation = ball.map { BallObservation(frameIndex: frame, timestampMs: ms, x: $0.x, y: $0.y, width: $0.width, height: $0.height, confidence: $0.score) }
                counter.push(frameIndex: frame, timestampMs: ms, ball: observation, person: person, sourceFrameIndex: sourceIndex)
                rowIndex += 1
            }
        }
        counter.flush()
        let trace = try XCTUnwrap(counter.traceSnapshot())
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let bytes = try encoder.encode(trace)
        let restored = try PropertyListDecoder().decode(CounterTrace.self, from: bytes)
        let verifierCalls = verifier.checkedContacts
        let replayStart = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try restored.replay(), counter.touches)
        let replayMS = (ProcessInfo.processInfo.systemUptime - replayStart) * 1000
        XCTAssertEqual(verifier.checkedContacts, verifierCalls, "Trace replay must not call Vision")
        try bytes.write(to: folder.appendingPathComponent("captured-counter-trace.plist"))
        var handVerdicts: [Int: Bool] = [:]
        for decision in trace.decisions {
            if let rejected = decision.value.handRejected { handVerdicts[decision.value.frameIndex] = rejected }
        }
        var untracedMS: [Double] = [], tracedMS: [Double] = []
        for iteration in 0..<12 {
            let tracing = iteration % 2 == 0
            let start = ProcessInfo.processInfo.systemUptime
            let c = StreamingCounter(config: trace.config, rejectsHandContact: { handVerdicts[$0] ?? false }, recordTrace: tracing)
            for operation in trace.operations {
                if operation.flush { c.flush() }
                else if let i = operation.input {
                    c.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs, ball: i.ball, person: i.person,
                           cameraOffsetY: i.cameraOffsetY, reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex)
                }
            }
            let elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(c.touches, counter.touches)
            if tracing { tracedMS.append(elapsedMS) } else { untracedMS.append(elapsedMS) }
        }
        let actual = counter.touches.map { Double($0.timestampMs) / 1000 }
        var report: [String: Any] = ["scope": "Physical iPhone; frozen captured rows at saved cadence and source pixels; not new camera capture. Missing original camera offsets/person-only frames are not reconstructed.",
            "frames": rowIndex, "source_frames": sourceIndex, "touches": actual,
            "trace_exact": true, "trace_bytes": bytes.count, "trace_replay_ms": replayMS,
            "counter_untraced_ms_median": untracedMS.sorted()[untracedMS.count / 2],
            "counter_traced_ms_median": tracedMS.sorted()[tracedMS.count / 2],
            "count": counter.count, "checks": checks, "actual_held_event_rejected": heldVerified,
            "warmup_ms": verifier.warmUpMS, "check_ms": verifier.totalCheckMS,
            "buffer_ms": bufferMS, "peak_buffered_frames": verifier.peakBufferedFrames,
            "elapsed_s": ProcessInfo.processInfo.systemUptime - started,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
        if let memory = DetectorRecordingReview.memory() { report["peak_bytes"] = memory.peak }
        if let error = verifier.lastError { report["error"] = error }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("phone-report.json"))
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(rowIndex, rows.count)
        XCTAssertNil(verifier.lastError)
        XCTAssertTrue(heldVerified, "The actual live false event at 2.833 s must be recognized as hands")
        XCTAssertEqual(actual.count, 18)
        for (prediction, reference) in zip(actual, expected) { XCTAssertEqual(prediction, reference, accuracy: 0.12) }
        XCTAssertLessThanOrEqual(verifier.peakBufferedFrames, 16)
        #endif
    }
}
