#if DEBUG
import AVFoundation
import XCTest
@testable import kicklab

@MainActor
final class WallRecordingTests: XCTestCase {
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 160, CVPixelBufferGetBytesPerRow(pixels) * 64)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    func testAllStopReasonsFinalizePlayableVideoAndShotData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try frame()
        for reason in ["long_press", "stop_button", "round_complete", "thermal_critical"] {
            let recorder = try WallTargetsRecorder(size: CGSize(width: 64, height: 64), metadata: [:], root: root)
            recorder.setPhase("mapping_check")
            recorder.noteMapping(WallMappingCheck.check([], on: [], off: [],
                corners: WallMappingFixture.corners, size: WallMappingFixture.size))
            recorder.noteMapping(WallMappingFixture.report(corners: WallMappingFixture.corners))
            for i in 0..<12 {
                if i == 3 { recorder.setPhase("playing") }
                recorder.append(pixels, at: CMTime(seconds: 100 + Double(i) / 30, preferredTimescale: 600),
                                ball: nil, person: nil, hand: .clear, inferenceRan: i >= 3)
                try await Task.sleep(for: .milliseconds(10))
            }
            recorder.note(.init(t: 100.1, x: 20, y: 30, d: 12, turn: 60, u: 0.3, v: 0.4, box: 1))
            let contact = WallImpactDetector.Impact(t: 100.1, x: 20, y: 30, d: 12, turn: 60, u: 0.3, v: 0.4, box: 1)
            recorder.noteFeedback(contact, at: 100.2, kind: "preview")
            recorder.noteFeedback(contact, at: 100.3, kind: "confirmed")
            recorder.noteFeedbackDelivery(contact, evidenceFrame: 100.3, decisionReady: 100.35,
                mainActorReceived: 100.36, callbackCompleted: 100.365, accepted: true)
            recorder.noteFeedbackDelivery(contact, evidenceFrame: 100.4, decisionReady: 100.45,
                mainActorReceived: 100.46, callbackCompleted: 100.465, accepted: false)
            recorder.noteResources(.init(uptime: 100.2, memoryMiB: 480, peakMemoryMiB: 500,
                thermalState: 2, analysisFPS: 24, captureFPS: 60, inferenceMS: 30, cameraResting: false,
                work: .init(windowSeconds: 1, stages: ["boardModel": .init(calls: 15, totalMS: 300, maximumMS: 25)],
                            referenceFramesSkipped: 45)))
            recorder.noteResources(.init(uptime: 100.3, memoryMiB: 470, peakMemoryMiB: 500,
                thermalState: 3, analysisFPS: 24, captureFPS: 60, inferenceMS: 30, cameraResting: false))
            recorder.setPhase("finished")
            let result = await recorder.finish(extra: ["stopReason": reason, "clears": [2.5]])
            XCTAssertTrue(result.succeeded, result.error ?? "")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("session.json"))) as! [String: Any]
            XCTAssertEqual(json["status"] as? String, "completed")
            XCTAssertEqual(json["stopReason"] as? String, reason)
            XCTAssertEqual((json["impacts"] as? [[String: Any]])?.count, 1)
            let feedback = try XCTUnwrap(json["feedbackEvents"] as? [[String: Any]])
            XCTAssertEqual(feedback.compactMap { $0["kind"] as? String }, ["preview", "confirmed"])
            XCTAssertEqual(try XCTUnwrap(feedback.first?["contactTime"] as? Double), 0.1, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(feedback.last?["reported"] as? Double), 0.3, accuracy: 0.001)
            let deliveries = try XCTUnwrap(json["feedbackDeliveries"] as? [[String: Any]])
            XCTAssertEqual(deliveries.count, 2)
            let delivery = try XCTUnwrap(deliveries.first)
            XCTAssertEqual(try XCTUnwrap(delivery["contactTime"] as? Double), 0.1, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(delivery["evidenceFrameTime"] as? Double), 0.3, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(delivery["decisionReadyTime"] as? Double), 0.35, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(delivery["mainActorReceivedTime"] as? Double), 0.36, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(delivery["callbackCompletedTime"] as? Double), 0.365, accuracy: 0.001)
            XCTAssertEqual(delivery["accepted"] as? Bool, true)
            XCTAssertEqual(deliveries.last?["accepted"] as? Bool, false)
            XCTAssertEqual(json["resourceSampleCount"] as? Int, 2)
            XCTAssertEqual(json["sampledPeakMemoryMiB"] as? Double, 480)
            XCTAssertEqual(json["worstThermalState"] as? Int, 3)
            let resourceLines = try String(contentsOf: result.folder.appendingPathComponent("resources.jsonl"),
                                           encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(resourceLines.count, 2)
            let resource = try JSONSerialization.jsonObject(with: Data(resourceLines[0].utf8)) as! [String: Any]
            XCTAssertEqual(try XCTUnwrap(resource["t"] as? Double), 0.2, accuracy: 0.001)
            XCTAssertEqual(resource["memoryMiB"] as? Double, 480)
            XCTAssertEqual(resource["analysisFPS"] as? Double, 24)
            let work = try XCTUnwrap(resource["work"] as? [String: Any])
            XCTAssertEqual(work["referenceFramesSkipped"] as? Int, 45)
            let stages = try XCTUnwrap(work["stages"] as? [String: [String: Any]])
            XCTAssertEqual(stages["boardModel"]?["calls"] as? Int, 15)
            XCTAssertEqual((json["phases"] as? [[String: Any]])?.last?["phase"] as? String, "finished")
            XCTAssertEqual((json["mappingChecks"] as? [[String: Any]])?.compactMap { $0["status"] as? String },
                           ["missingPoints", "passed"])
            XCTAssertEqual((json["mappingCheck"] as? [String: Any])?["status"] as? String, "passed")
            let csv = try String(contentsOf: result.folder.appendingPathComponent("detections.csv"), encoding: .utf8)
            XCTAssertEqual(csv.split(separator: "\n")[1].split(separator: ",")[13], "4")
            XCTAssertEqual(csv.split(separator: "\n")[0].split(separator: ",").last, "inference_ran")
            XCTAssertEqual(csv.split(separator: "\n")[1].split(separator: ",").last, "0")
            XCTAssertEqual(csv.split(separator: "\n").last?.split(separator: ",").last, "1")
            let rows = csv.split(separator: "\n").count - 1
            XCTAssertGreaterThan(rows, 0)
            XCTAssertEqual(json["frames"] as? Int, rows)
            let asset = AVURLAsset(url: result.folder.appendingPathComponent("video.mov"))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil { frames += 1 }
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(frames, rows)
        }
    }

    func testRapidNewSessionNeverReusesAnExistingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try WallTargetsRecorder(size: CGSize(width: 64, height: 64), metadata: ["session": 1], root: root)
        let second = try WallTargetsRecorder(size: CGSize(width: 64, height: 64), metadata: ["session": 2], root: root)
        XCTAssertNotEqual(first.folder, second.folder)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: first.folder.appendingPathComponent("session.json"))) as! [String: Any]
        XCTAssertEqual(json["session"] as? Int, 1)
        _ = await first.finish(extra: [:])
        _ = await second.finish(extra: [:])
    }
}
#endif
