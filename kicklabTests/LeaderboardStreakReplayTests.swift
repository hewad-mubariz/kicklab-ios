import AVFoundation
import XCTest
@testable import kicklab

/// Opt-in real-pixel regression. Compare the same decoded pixels with/without
/// streak tracking, then freeze original contact decisions to isolate ranking
/// from differences between live camera pixels and the encoded replay.
final class LeaderboardStreakReplayTests: XCTestCase {
    private struct Configuration: Decodable {
        struct Clip: Decodable {
            let id, video, archive: String
            let expectedTotal, expectedStreak: Int
            let duration: Double
        }
        let clips: [Clip]
    }

    @MainActor
    func testRecordedInterruptionsAndCleanControl() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run the saved-pixel Vision regression on the connected phone")
        #else
        let folder = URL.documentsDirectory.appendingPathComponent("LeaderboardStreakRegression")
        let configURL = folder.appendingPathComponent("config.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: configURL.path), "No private video corpus staged")
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        for clip in config.clips {
            let archive = try PropertyListDecoder().decode(CounterTraceArchive.self,
                from: Data(contentsOf: folder.appendingPathComponent(clip.archive)))
            var baseline: Result?
            for mode in [Mode.baseline, .current, .originalContacts] {
                let result = try await VideoWorkExecution.detached {
                    try await Self.replay(folder.appendingPathComponent(clip.video), archive: archive, duration: clip.duration, mode: mode)
                }.value
                let name = clip.id+"-"+mode.rawValue
                try result.report.write(to: folder.appendingPathComponent(name+"-result.json"), options: .atomic)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(result.trace).write(to: folder.appendingPathComponent(name+"-after.plist"), options: .atomic)
                XCTAssertEqual(try result.trace.replay(), result.trace.touches)
                if mode == .baseline { baseline = result }
                if mode == .current {
                    XCTAssertEqual(result.trace.touches, baseline?.trace.touches, "Streak tracking changed replay contacts: \(clip.id)")
                    XCTAssertEqual(result.trace.decisions, baseline?.trace.decisions, "Streak tracking changed a counter decision: \(clip.id)")
                }
                if mode == .originalContacts {
                    XCTAssertEqual(result.trace.touches, archive.trace.touches, "Original training count changed: \(clip.id)")
                    XCTAssertEqual(result.trace.touches.count, clip.expectedTotal, clip.id)
                    XCTAssertEqual(result.streak?.count, clip.expectedStreak, clip.id)
                }
            }
        }
        #endif
    }

    private struct Result: Sendable { let trace: CounterTrace; let streak: RankedStreakProposal?; let report: Data }
    private enum Mode: String, Sendable { case baseline, current, originalContacts }
    private static func replay(_ video: URL, archive: CounterTraceArchive, duration: Double, mode: Mode) async throws -> Result {
        let asset = AVURLAsset(url: video)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false; reader.add(output)
        let verifier = JugglingContactVerifier(); verifier.warmUp()
        let provider = ReplayEvidence(verifier: verifier, mode: mode, trace: archive.trace)
        let counter = ContactCounterFactory.make(verifier: provider, config: archive.trace.config)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "StreakReader", code: 1) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let start = ProcessInfo.processInfo.systemUptime
        var sourceIndex = 0, operation = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                defer { sourceIndex += 1 }
                guard operation < archive.trace.operations.count,
                      let input = archive.trace.operations[operation].input,
                      input.sourceFrameIndex == sourceIndex else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard abs(time-(Double(input.timestampMs)/1000-archive.timeOriginSeconds)) < 0.002,
                      let pixels = CMSampleBufferGetImageBuffer(sample) else { throw NSError(domain: "StreakFrameMismatch", code: sourceIndex) }
                let ball = input.ball.map { Detection(score: $0.confidence, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                if !input.reliable { verifier.discardFrames() }
                else { verifier.store(pixels, frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                    ball: ball, orientLandscapeAsPortrait: false, player: input.player) }
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball,
                    person: input.person, cameraOffsetY: input.cameraOffsetY, reliable: input.reliable,
                    sourceFrameIndex: sourceIndex, player: input.player)
                operation += 1
            }
        }
        guard reader.status == .completed, operation == archive.trace.operations.count-1 else {
            throw reader.error ?? NSError(domain: "StreakReplayIncomplete", code: operation)
        }
        counter.flush()
        guard verifier.lastError == nil, let trace = counter.traceSnapshot(),
              verifier.peakBufferedFrames <= ContactFrameWindow.maximumBufferedFrames else {
            throw NSError(domain: verifier.lastError ?? "StreakEvidenceBuffer", code: 1)
        }
        let times = counter.touches.map { Double($0.timestampMs)/1000-archive.timeOriginSeconds }
        let review = LeaderboardTouchReview.make(evidence: counter.reviewEvidence, touchTimes: times,
            duration: duration, timeOrigin: archive.timeOriginSeconds)
        let streak = RankedStreakProposal.suggest(touchTimes: times, boundaries: review?.streakBoundaries ?? [], duration: duration)
        let report: [String: Any] = [
            "total": times.count, "streak": streak.map { $0.count } as Any? ?? NSNull(),
            "touches": times, "boundaries": review?.streakBoundaries ?? [],
            "moments": try review.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } as Any? ?? NSNull(),
            "poseRequests": verifier.poseRequests, "poseCacheHits": verifier.poseCacheHits,
            "peakBufferedFrames": verifier.peakBufferedFrames,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime-start
        ]
        return .init(trace: trace, streak: streak,
            report: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys,.prettyPrinted]))
    }

    private final class ReplayEvidence: ContactEvidenceProviding {
        let verifier: JugglingContactVerifier
        let mode: Mode
        let decisions: [Int: CounterDecision]
        let diagnostics: [Int: TouchDebugEvent]
        init(verifier: JugglingContactVerifier, mode: Mode, trace: CounterTrace) {
            self.verifier = verifier; self.mode = mode
            decisions = Dictionary(trace.decisions.map { ($0.value.frameIndex,$0.value) }, uniquingKeysWith: { first,_ in first })
            diagnostics = Dictionary((trace.diagnostics ?? []).map { ($0.frameIndex,$0) }, uniquingKeysWith: { first,_ in first })
        }
        func configure(policy: CountingPolicy) { verifier.configure(policy: policy) }
        func retainContactFrames(around index: Int?) { verifier.retainContactFrames(around: index) }
        func rejectsHandContact(at frameIndex: Int) -> Bool {
            mode == .originalContacts ? decisions[frameIndex]?.handRejected ?? false : verifier.rejectsHandContact(at: frameIndex)
        }
        func allowsBodyContact(at frameIndex: Int, policy: CountingPolicy.BodyContact) -> Bool {
            mode == .originalContacts ? decisions[frameIndex]?.bodyContactAllowed ?? false : verifier.allowsBodyContact(at: frameIndex, policy: policy)
        }
        func footEvidence(at frameIndex: Int) -> FootContactEvidence? {
            mode == .originalContacts ? decisions[frameIndex]?.footEvidence : verifier.footEvidence(at: frameIndex)
        }
        func groundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? {
            mode == .originalContacts ? decisions[frameIndex]?.groundEvidence : verifier.groundEvidence(at: frameIndex, timed: timed)
        }
        func handlingEvidence(at frameIndex: Int) -> BallHandlingEvidence? {
            mode == .originalContacts ? decisions[frameIndex]?.handlingEvidence : verifier.handlingEvidence(at: frameIndex)
        }
        func diagnostic(for decision: CounterDecision, ball: BallObservation?) -> TouchDebugEvent {
            if mode == .originalContacts, let diagnostic = diagnostics[decision.frameIndex] { return diagnostic }
            return verifier.diagnostic(for: decision, ball: ball)
        }
        func streakHandlingEvidence(now: Int, after lastTouchMs: Int) -> BallHandlingEvidence? {
            mode == .baseline ? nil : verifier.streakHandlingEvidence(now: now, after: lastTouchMs)
        }
        func streakGroundEvidence(at frameIndex: Int, timed: Bool) -> GroundContactEvidence? {
            mode == .baseline ? nil : verifier.streakGroundEvidence(at: frameIndex, timed: timed)
        }
    }
}
