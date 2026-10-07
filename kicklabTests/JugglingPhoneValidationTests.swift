import AVFoundation
import XCTest
@testable import kicklab

/// Explicit local-fixture test. Uses the current native detector and contact
/// verifier together, then exports Fire and Ice with the resulting track.
/// File replay throughput is not live-camera FPS or a thermal endurance test.
final class JugglingPhoneValidationTests: XCTestCase {
    @MainActor
    func testRecordedContactsAndEffectsOnPhone() async throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JugglingValidation-20261003", isDirectory: true)
        let video = Bundle(for: type(of: self)).url(forResource: "juggling-eighteen", withExtension: "mov")
            ?? folder.appendingPathComponent("raw-juggling.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: video.path), "Requires the reviewed 18-foot + 2-hand fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reportURL = folder.appendingPathComponent("phone-report.json")
        var report: [String: Any] = ["status": "running", "model": "YOLOX-Tiny fine-tuned crop v3",
            "scope": "XCTest: decoded file + actual detector + candidate-only pose, then Fire/Ice export. Not live camera FPS or whole consumer workflow."]
        #if targetEnvironment(simulator)
        report["hardware"] = "simulator_not_phone"
        #else
        report["hardware"] = "physical_device"
        #endif
        func save() throws {
            if let memory = DetectorRecordingReview.memory() {
                report["current_bytes"] = memory.current
                report["kernel_peak_bytes"] = memory.peak
                report["within_300_MB"] = memory.peak < 300_000_000
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        try save()
        let result = try await Self.analyze(video: video)
        report["analysis"] = result.report
        try save()
        var exports: [[String: Any]] = []
        for style in [BallStyle.fire, .ice] {
            let output = try await BallStyleBurnIn.render(source: video, track: result.frames,
                style: style, intensity: 0.8, shortEdge: 720)
            let destination = folder.appendingPathComponent("\(style.rawValue)-verified.mp4")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: output, to: destination)
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            exports.append(["style": style.rawValue, "duration_s": duration,
                "bytes": (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0])
            report["exports"] = exports
            try save()
            XCTAssertGreaterThan(duration, 18)
        }
        report["status"] = result.report["hand_check_error"] == nil
            ? "completed" : "exports_completed_contacts_unavailable"
        report["thermal"] = ProcessInfo.processInfo.thermalState.rawValue
        try save()
        #if targetEnvironment(simulator)
        if let error = result.report["hand_check_error"] as? String {
            throw XCTSkip("Exports completed, but this simulator cannot validate contacts: \(error)")
        }
        #endif
        XCTAssertNil(result.report["hand_check_error"], "Hand checking must be available on the phone")
        XCTAssertEqual(result.count, 18, "All 18 reviewed foot contacts must remain")
        XCTAssertEqual(result.hands, 2, "Both reviewed handling events must be excluded")
        let labelsURL = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "juggling-eighteen-events", withExtension: "json"))
        let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: labelsURL)) as! [String: Any]
        let expected = (labels["events"] as! [[String: Any]])
            .filter { $0["counts"] as? Bool == true }.map { $0["time_s"] as! Double }
        let actual = (result.report["touches"] as! [[String: Double]]).map { $0["time"]! }
        XCTAssertEqual(actual.count, expected.count)
        // Anchors are spaced well beyond this tolerance: ordered one-to-one
        // correspondence catches a missing touch canceled out by an extra one.
        for (prediction, reference) in zip(actual, expected) {
            XCTAssertEqual(prediction, reference, accuracy: 0.12)
        }
    }

    private struct Result {
        let frames: [RecordedFrame]
        let count, hands: Int
        let report: [String: Any]
    }

    @MainActor
    private static func analyze(video: URL) async throws -> Result {
        let asset = AVURLAsset(url: video)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        let detector = try BallDetector(resourceName: "KickLabYOLOXTinyFineTuned", useROI: true)
        let verifier = JugglingContactVerifier()
        let counter = StreamingCounter(rejectsHandContact: { verifier.rejectsHandContact(at: $0) })
        var plausibility = BallPlausibility()
        var frames: [RecordedFrame] = []
        var costs: [Double] = []
        var index = 0
        let started = ProcessInfo.processInfo.systemUptime
        while let sample = output.copyNextSampleBuffer() {
            try autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), stamp = Int(time * 1000)
                var found = try detector.detect(pixels, orientLandscapeAsPortrait: false, timestamp: time)
                if let ball = found.ball { found.ball = plausibility.accept(ball, frame: index) }
                let person = found.person.map { PersonBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                verifier.store(pixels, frameIndex: index, timestampMs: stamp, ball: found.ball, orientLandscapeAsPortrait: false)
                let observation = found.ball.map { BallObservation(frameIndex: index, timestampMs: stamp,
                    x: $0.x, y: $0.y, width: $0.width, height: $0.height, confidence: $0.score) }
                counter.push(frameIndex: index, timestampMs: stamp, ball: observation, person: person)
                if let b = found.ball {
                    frames.append(RecordedFrame(time: time, x: b.x, y: b.y, width: b.width, height: b.height,
                        score: b.score, smoothedX: b.x, smoothedY: b.y, vy: counter.lastPoint?.vy ?? 0,
                        motion: counter.lastPoint?.motion ?? .unknown, detected: true, person: person))
                }
                index += 1
                costs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        if reader.status == .failed { throw reader.error! }
        counter.flush()
        var report: [String: Any] = ["frames": index, "count": counter.count,
            "hand_rejections": verifier.rejectedContacts, "checked_contacts": verifier.checkedContacts,
            "elapsed_s": ProcessInfo.processInfo.systemUptime - started, "processing_ms": costs,
            "touches": counter.touches.map { ["time": Double($0.timestampMs) / 1000, "x": $0.x, "y": $0.y] },
            "kernel_peak_bytes": DetectorRecordingReview.memory()?.peak ?? 0]
        if let error = verifier.lastError { report["hand_check_error"] = error }
        return Result(frames: frames, count: counter.count, hands: verifier.rejectedContacts, report: report)
    }
}
