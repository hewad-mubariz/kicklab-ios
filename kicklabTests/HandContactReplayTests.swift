import AVFoundation
import XCTest
@testable import kicklab

/// Replays frozen detector observations with the original pixels through the real
/// verifier and counter. This isolates contact changes from model/backend changes.
final class HandContactReplayTests: XCTestCase {
    @MainActor
    func testDelayedContactRetainsOnlyBoundedImagesAndReleasesThem() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device Vision check")
        #else
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 72, 128, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let verifier = JugglingContactVerifier()
        let ball = Detection(score: 0.9, x: 0.5, y: 0.4, width: 0.1, height: 0.1)
        for frame in 0...120 {
            verifier.store(buffer, frameIndex: frame, timestampMs: frame * 33, ball: ball)
            if frame == 7 { verifier.retainContactFrames(around: 3) }
        }
        XCTAssertFalse(verifier.rejectsHandContact(at: 3), "Blank pixels cannot identify a hand")
        XCTAssertNil(verifier.lastError)
        XCTAssertEqual(verifier.checkedContacts, 1, "The delayed contact must still have its images")
        XCTAssertLessThanOrEqual(verifier.peakBufferedFrames, 29)
        verifier.retainContactFrames(around: nil)
        verifier.store(buffer, frameIndex: 121, timestampMs: 121 * 33, ball: ball)
        XCTAssertFalse(verifier.rejectsHandContact(at: 3))
        XCTAssertEqual(verifier.checkedContacts, 1, "Released images must leave the cache")
        verifier.discardFrames()
        XCTAssertFalse(verifier.rejectsHandContact(at: 121))
        #endif
    }

    private struct Configuration: Decodable {
        struct Clip: Decodable {
            let id, video, trace: String
            let preserveBaseline: Bool
            let forbiddenIntervals: [[Double]]
        }
        let run: String
        let clips: [Clip]
    }

    @MainActor
    func testFrozenObservationsWithRealContactPixels() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical-device Vision and the explicit local regression corpus")
        #else
        let root = URL.documentsDirectory.appendingPathComponent("HandContactRegression")
        let configURL = root.appendingPathComponent("config.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: configURL.path), "Stage the reviewed local corpus first")
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        for clip in config.clips {
            let trace = try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: root.appendingPathComponent(clip.trace)))
            XCTAssertTrue(trace.complete)
            XCTAssertTrue(trace.operations.last?.flush == true)
            let result = try await VideoWorkExecution.$accuracyComparison.withValue(true) {
                try await VideoWorkExecution.detached {
                    try await Self.replay(root.appendingPathComponent(clip.video), trace: trace)
                }.value
            }
            let folder = root.appendingPathComponent(config.run)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try result.report.write(to: folder.appendingPathComponent(clip.id + ".json"), options: .atomic)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(result.trace).write(to: folder.appendingPathComponent(clip.id + "-trace.plist"))
            if clip.preserveBaseline {
                XCTAssertEqual(result.trace.touches.map(\.timestampMs), trace.touches.map(\.timestampMs), clip.id)
            }
            for interval in clip.forbiddenIntervals {
                XCTAssertFalse(result.trace.touches.contains { interval[0] <= Double($0.timestampMs)/1000 && Double($0.timestampMs)/1000 <= interval[1] },
                               "\(clip.id): accepted a contact in reviewed hand-only interval \(interval)")
            }
        }
        #endif
    }

    private struct Result: Sendable {
        let trace: CounterTrace
        let report: Data
    }

    private static func replay(_ source: URL, trace: CounterTrace) async throws -> Result {
        let asset = AVURLAsset(url: source)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: track, duration: asset.load(.duration), shortEdge: 720)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let verifier = JugglingContactVerifier()
        verifier.warmUp()
        var decisions: [[String: Any]] = []
        let counter = StreamingCounter(config: trace.config, rejectsHandContact: { frame in
            let rejected = verifier.rejectsHandContact(at: frame)
            decisions.append(["frame": frame, "rejected": rejected])
            return rejected
        }, recordTrace: true, footContactEvidence: trace.usesFootVerifier ? { verifier.footEvidence(at: $0) } : nil,
           retainContactFrames: { verifier.retainContactFrames(around: $0) })
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "ContactReplayReader", code: 1) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var index = 0
        let started = ProcessInfo.processInfo.systemUptime
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard index < trace.operations.count, let input = trace.operations[index].input,
                      input.sourceFrameIndex == index,
                      let pixels = CMSampleBufferGetImageBuffer(sample) else {
                    throw NSError(domain: "ContactReplayFrameMismatch", code: index)
                }
                let stamp = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000)
                guard abs(stamp - input.timestampMs) <= 1 else { throw NSError(domain: "ContactReplayTimestampMismatch", code: index) }
                let ball = input.ball.map { Detection(score: $0.confidence, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                if !input.reliable { verifier.discardFrames() }
                else { verifier.store(pixels, frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: ball, orientLandscapeAsPortrait: false) }
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball,
                             person: input.person, cameraOffsetY: input.cameraOffsetY, reliable: input.reliable, sourceFrameIndex: index)
                index += 1
            }
        }
        guard reader.status == .completed, index == trace.operations.count - 1 else {
            throw reader.error ?? NSError(domain: "ContactReplayIncomplete", code: index)
        }
        counter.flush()
        guard verifier.lastError == nil else { throw NSError(domain: verifier.lastError!, code: 1) }
        let result = counter.traceSnapshot()!
        return Result(trace: result, report: try JSONSerialization.data(withJSONObject: ["count": counter.count, "frames": index,
            "touch_times": counter.touches.map { Double($0.timestampMs)/1000 }, "decisions": decisions,
            "hand_rejections": verifier.rejectedContacts, "checks": verifier.checkedContacts,
            "pose_requests": verifier.poseRequests, "hand_pose_requests": verifier.handPoseRequests, "check_ms": verifier.totalCheckMS,
            "peak_buffered_frames": verifier.peakBufferedFrames,
            "elapsed_s": ProcessInfo.processInfo.systemUptime - started], options: [.prettyPrinted, .sortedKeys]))
    }
}
