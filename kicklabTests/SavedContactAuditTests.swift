#if DEBUG
import AVFoundation
import XCTest
@testable import kicklab

/// Opt-in saved-pixel audit. Frozen ball observations and original source PTS
/// isolate contact rules from detector changes; no new model inference runs.
final class SavedContactAuditTests: XCTestCase {
    private struct Replays: Decodable {
        struct Window: Decodable {
            struct Row: Decodable { let sourceTime: Double; let input: CounterTrace.Input }
            let id: String
            let rows: [Row]
            let expectedAddedFrames: [Int]
        }
        let sourceDigest: String
        let config: CounterConfig
        let replays: [Window]
    }

    func testSavedCounterWindows() async throws {
        let folder = URL.documentsDirectory.appendingPathComponent("SavedContactAudit")
        let config = folder.appendingPathComponent("replays.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: config.path), "No saved counter audit staged")
        let audit = try JSONDecoder().decode(Replays.self, from: Data(contentsOf: config))
        let video = folder.appendingPathComponent("source.mov")
        XCTAssertEqual(try SessionAnalysisStore.sourceDigest(video), audit.sourceDigest)
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        for window in audit.replays {
            var baseline: CounterTrace?
            for body in [CountingPolicy.BodyContact.independentLegV12, .legReboundV13] {
                let verifier = JugglingContactVerifier()
                let policy = CountingPolicy(handling: .sustainedGripV1, verifiesContacts: true,
                    body: body, ground: .corroboratedFeet)
                let counter = ContactCounterFactory.make(verifier: verifier, policy: policy, config: audit.config)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                output.alwaysCopiesSampleData = false
                reader.add(output)
                let start = max(0, try XCTUnwrap(window.rows.first).sourceTime - 0.1)
                let end = try XCTUnwrap(window.rows.last).sourceTime + 0.002
                reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1_000_000_000),
                    end: CMTime(seconds: end, preferredTimescale: 1_000_000_000))
                XCTAssertTrue(reader.startReading())
                var index = 0
                while let sample = output.copyNextSampleBuffer() {
                    try autoreleasepool {
                        guard index < window.rows.count else { return }
                        let row = window.rows[index], input = row.input
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if time < row.sourceTime-0.002 { return }
                        XCTAssertEqual(time, row.sourceTime, accuracy: 0.002)
                        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                        let ball = input.ball.map { Detection(score: $0.confidence, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                        if !input.reliable { verifier.discardFrames() }
                        else { verifier.store(pixels, frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                            ball: ball, orientLandscapeAsPortrait: false) }
                        counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball,
                            person: input.person, cameraOffsetY: input.cameraOffsetY, reliable: input.reliable,
                            sourceFrameIndex: input.sourceFrameIndex)
                        index += 1
                    }
                }
                XCTAssertEqual(reader.status, .completed)
                XCTAssertEqual(index, window.rows.count)
                counter.flush()
                let trace = try XCTUnwrap(counter.traceSnapshot())
                XCTAssertEqual(try trace.replay(), counter.touches)
                XCTAssertNil(verifier.lastError)
                XCTAssertLessThanOrEqual(verifier.peakBufferedFrames, ContactFrameWindow.maximumBufferedFrames)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(trace).write(to: folder.appendingPathComponent("\(window.id)-\(body.rawValue).plist"))
                if body == .independentLegV12 { baseline = trace }
                else if let baseline {
                    let previous = Set(baseline.touches.map(\.frameIndex)), current = Set(trace.touches.map(\.frameIndex))
                    XCTAssertEqual(current.subtracting(previous), Set(window.expectedAddedFrames), window.id)
                    XCTAssertTrue(previous.isSubset(of: current), "Lost an existing touch in \(window.id)")
                    let previousGround = baseline.decisions.filter { $0.value.rejection == .groundBounce }.map { $0.value.frameIndex }
                    let currentGround = trace.decisions.filter { $0.value.rejection == .groundBounce }.map { $0.value.frameIndex }
                    XCTAssertEqual(currentGround, previousGround, "Changed a floor verdict in \(window.id)")
                }
            }
        }
    }

    private struct Audit: Decodable {
        struct Input: Decodable {
            let frame, timestampMs: Int
            let sourceTime: Double
            let ball: [Double]?
        }
        struct Contact: Decodable {
            let id, label: String
            let frame, timestampMs: Int
            let inputs: [Input]
            let auditResolution: Bool?
        }
        let sourceDigest: String
        let contacts: [Contact]
    }

    func testSavedContactWindows() async throws {
        let folder = URL.documentsDirectory.appendingPathComponent("SavedContactAudit")
        let config = folder.appendingPathComponent("config.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: config.path), "No saved contact audit staged")
        let audit = try JSONDecoder().decode(Audit.self, from: Data(contentsOf: config))
        let video = folder.appendingPathComponent("source.mov")
        XCTAssertEqual(try SessionAnalysisStore.sourceDigest(video), audit.sourceDigest)
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        var results: [[String: Any]] = []
        for contact in audit.contacts {
            var alternatePoses: [[String: Any]] = []
            let store = ContactObservationStore()
            let verifier = JugglingContactVerifier(observations: store)
            verifier.retainContactFrames(around: contact.frame)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            // Reader may trim the first sample's PTS to timeRange.start. Start
            // earlier and discard that sample, then match original exposures.
            let start = max(0, try XCTUnwrap(contact.inputs.first).sourceTime - 0.1)
            let end = try XCTUnwrap(contact.inputs.last).sourceTime + 0.002
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1_000_000_000),
                end: CMTime(seconds: end, preferredTimescale: 1_000_000_000))
            XCTAssertTrue(reader.startReading())
            var index = 0
            while let sample = output.copyNextSampleBuffer() {
                try autoreleasepool {
                    guard index < contact.inputs.count else { return }
                    let row = contact.inputs[index]
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if time < row.sourceTime - 0.002 { return }
                    XCTAssertEqual(time, row.sourceTime, accuracy: 0.002)
                    let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                    let ball = row.ball.map { Detection(score: $0[4], x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                    verifier.store(pixels, frameIndex: row.frame, timestampMs: row.timestampMs,
                        ball: ball, orientLandscapeAsPortrait: false)
                    if contact.auditResolution == true,
                       (-150...150).contains(row.timestampMs-contact.timestampMs),
                       let frame = store.frames.first(where: { $0.index == row.frame }) {
                        alternatePoses.append(try ContactPoseAudit.inspect(frame,source:pixels))
                    }
                    index += 1
                }
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(index, contact.inputs.count)
            let allowed = verifier.allowsBodyContact(at: contact.frame, policy: .independentLegV12)
            let recovered = verifier.allowsBodyContact(at: contact.frame, policy: .legReboundV13)
            let hand = verifier.rejectsHandContact(at: contact.frame)
            let ground = verifier.groundEvidence(at: contact.frame, timed: true)
            let handling = verifier.handlingEvidence(at: contact.frame)
            if contact.label == "hand" {
                XCTAssertFalse(recovered, contact.id)
                XCTAssertTrue(hand, contact.id)
            }
            let samples = store.frames.filter { (-350...250).contains($0.timestampMs-contact.timestampMs) }.map { frame -> [String: Any] in
                let pose = store.pose(for: frame) ?? BodyPose()
                return ["timestampMs": frame.timestampMs, "frame": frame.index,
                    "ball": [frame.ball.x, frame.ball.y, frame.ball.width, frame.ball.height, frame.ball.score,
                             Double(CVPixelBufferGetWidth(frame.pixels))/Double(CVPixelBufferGetHeight(frame.pixels))],
                    "joints": Dictionary(uniqueKeysWithValues: pose.joints.map { ($0.key.rawValue, [$0.value.x,$0.value.y]) }),
                    "landmarks": Dictionary(uniqueKeysWithValues: pose.landmarks.map { ($0.key.rawValue, [$0.value.x,$0.value.y,$0.value.confidence]) }),
                    "ankles": Dictionary(uniqueKeysWithValues: pose.ankles.map { ($0.key.rawValue, [$0.value.x,$0.value.y,$0.value.confidence]) })]
            }
            XCTAssertNil(verifier.lastError)
            XCTAssertLessThanOrEqual(verifier.peakBufferedFrames, ContactFrameWindow.maximumBufferedFrames)
            results.append(["id": contact.id, "contact": contact.label, "contactMs": contact.timestampMs,
                "frame": contact.frame, "bodyV12": allowed, "bodyV13": recovered, "hand": hand,
                "ground": ground?.confirmsGroundContact(corroboratingWeakAnkles: true) ?? false,
                "handling": handling?.state.rawValue ?? "absent", "samples": samples])
            try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("result.json"), options: .atomic)
            if !alternatePoses.isEmpty {
                try JSONSerialization.data(withJSONObject: alternatePoses, options: [.sortedKeys])
                    .write(to: folder.appendingPathComponent("\(contact.id)-resolution-audit.json"), options: .atomic)
            }
        }
    }
}
#endif
