import XCTest
import AVFoundation
@testable import kicklab

@MainActor
final class HistoryReplayEditorTests: XCTestCase {
    private var root: URL!
    private var library: SessionHistoryLibrary!
    override func setUp() {
        root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = SessionHistoryLibrary(root: root.appendingPathComponent("History"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func item(owner: UUID? = nil) -> HistorySession {
        HistorySession(id: UUID(), ownerID: owner, touches: 2, durationMS: 2000, source: .recording,
                       completedAt: Date(), syncState: .deviceOnly)
    }
    private func summary() -> SessionSummary {
        let mask = BallMask(rect: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), width: 2, height: 2, alpha: [255,255,255,255])
        let frame = RecordedFrame(time: 1, x: 0.4, y: 0.6, width: 0.1, height: 0.1, score: 0.9,
            smoothedX: 0.41, smoothedY: 0.61, vy: 0.3, motion: .rising, detected: true, person: nil,
            ballMask: mask, usesBallMasks: true)
        var value = SessionSummary.make(touches: 2, duration: 2, bestCombo: 2, personalBest: 8,
            videoURL: root.appendingPathComponent("source.mov"),
            touchesMarked: [.init(index: 1, time: 0.55, x: 0.4, y: 0.6), .init(index: 2, time: 1.45, x: 0.5, y: 0.7)],
            track: [frame], sessionNumber: 4)
        value.framesUseCompositionClock = true
        return value
    }

    func testReplayRoundTripKeepsOriginalTouchClockWithoutRetainingMasks() throws {
        let item = item(), original = summary()
        try library.saveReplayData(HistoryReplayData(summary: original), for: item)
        let persisted = try XCTUnwrap(library.replayData(for: item))
        let moved = root.appendingPathComponent("permanent.mov")
        let restored = persisted.summary(item: item, videoURL: moved)
        XCTAssertEqual(restored.videoURL, moved)
        XCTAssertEqual(restored.touches, original.touches)
        XCTAssertEqual(restored.touchesMarked.map(\.time), original.touchesMarked.map(\.time))
        XCTAssertEqual(restored.touchesMarked.map(\.x), original.touchesMarked.map(\.x))
        XCTAssertEqual(restored.track.first?.smoothedY, original.track.first?.smoothedY)
        XCTAssertEqual(restored.personalBest, 8)
        XCTAssertEqual(restored.sessionNumber, 4)
        XCTAssertNil(restored.track.first?.ballMask)
        XCTAssertTrue(restored.framesUseCompositionClock)
        XCTAssertTrue(restored.needsVisualPreparation)
        XCTAssertTrue(restored.visualTrackIsPositionsOnly, "Stripped masks must be rebuilt before ball replacement")
    }

    func testDraftKeepsExactCustomRunsSoundsAndOverlayPlacementAcrossRelaunch() throws {
        let item = item()
        var edit = SessionEditState(style: .water, intensity: 0.73456, ballSkin: .arctic, environment: .night)
        edit.lookChanges = [1: .init(ball: .lava, effect: .fire), 7: .init(ball: .goldPolish, effect: .none)]
        edit.clipAudio = false; edit.swapSoundChoice = .some(.none)
        var overlays = ExportOverlaySettings()
        overlays.counter.enabled = false
        overlays.counter.placement.x = 0.24
        overlays.counter.customLabel = "Ballkontakte"
        overlays.timer.enabled = true
        let draft = HistoryReplayEdit(edit: edit, overlays: overlays)
        try library.saveReplayEdit(draft, id: item.id, owner: item.ownerID)
        let relaunched = SessionHistoryLibrary(root: library.root)
        let restored = try XCTUnwrap(relaunched.replayEdit(for: item))
        XCTAssertEqual(restored.edit, edit)
        XCTAssertEqual(restored.overlays, overlays)
    }

    func testRebuildingLegacyReplayUsesSavedTouchTimesAndNeverRecountsHistory() {
        var item = item(); item.touchTimesMS = [550, 1450]
        let original = summary()
        let reopened = HistoryReplayData.rebuilt(item: item, videoURL: original.videoURL, duration: 2,
            frames: original.track, detectedTouches: [.init(index: 1, time: 0.9, x: 0.1, y: 0.1)])
        XCTAssertEqual(reopened.touches, 2)
        XCTAssertEqual(reopened.touchesMarked.map(\.time), [0.55,1.45])
        XCTAssertEqual(reopened.touchesMarked.map(\.index), [1,2])
        XCTAssertEqual(item.touches, 2)
    }

    func testLegacySessionWithoutTouchClockCanRebuildEditorOnly() throws {
        let item = item(), original = summary()
        try library.save(item)
        let rebuilt = HistoryReplayData.rebuilt(item: item, videoURL: original.videoURL, duration: 2,
            frames: original.track, detectedTouches: [.init(index: 1, time: 0.9, x: 0.1, y: 0.1)])
        try library.saveReplayData(HistoryReplayData(summary: rebuilt), for: item)
        XCTAssertEqual(try library.sessions(owner: nil), [item])
        XCTAssertEqual(rebuilt.touches, 2)
        XCTAssertEqual(rebuilt.touchesMarked.map(\.time), [0.9])
    }

    func testPendingSaveRetainsEditorDataAndRecoversWithoutAnEditOverwrite() async throws {
        let item = item(), original = summary()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: original.videoURL)
        let request = SessionSaveRequest(item: item, result: nil, videoURL: original.videoURL,
            replayData: HistoryReplayData(summary: original))
        let queue = JugglingResultQueue(root: root)
        _ = try request.persist(library: library, queue: queue)
        let edit = HistoryReplayEdit(edit: .init(style: .none, intensity: 0), overlays: .init())
        try library.saveReplayEdit(edit, id: item.id, owner: item.ownerID)
        let recovered = try XCTUnwrap(library.pendingRequests(owner: nil).first)
        _ = try recovered.persist(library: library, queue: queue)
        XCTAssertNotNil(try library.replayData(for: item))
        XCTAssertEqual(try library.replayEdit(for: item), edit)
        XCTAssertEqual(try library.sessions(owner: nil).count, 1)
    }

    func testLegacySaveJournalWithoutEditorDataStillDecodes() throws {
        let item = item()
        let request = SessionSaveRequest(item: item, result: nil, videoURL: root.appendingPathComponent("original.mov"))
        let decoded = try JSONDecoder().decode(SessionSaveRequest.self, from: JSONEncoder().encode(request))
        XCTAssertNil(decoded.replayData)
        _ = try decoded.persist(library: library, queue: .init(root: root))
        XCTAssertNil(try library.replayData(for: item))
    }

    func testRemovingReplayAlsoRemovesDraftButPreservesScoreAndSource() async throws {
        let item = item(), original = summary()
        try library.save(item)
        try Data([1,2,3]).write(to: original.videoURL)
        try await library.retainVideo(original.videoURL, for: item)
        try library.saveReplayData(.init(summary: original), for: item)
        try library.saveReplayEdit(.init(edit: .init(), overlays: .init()), id: item.id, owner: item.ownerID)
        try library.removeVideo(for: item)
        XCTAssertNil(library.videoURL(for: item))
        XCTAssertNil(try library.replayData(for: item))
        XCTAssertNil(try library.replayEdit(for: item))
        XCTAssertEqual(try library.sessions(owner: nil), [item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.videoURL.path))
    }

    func testEditorDraftRespectsAccountScopeAndDeletionGuard() throws {
        let owner = UUID(), item = item(owner: UUID())
        let draft = HistoryReplayEdit(edit: .init(), overlays: .init())
        try library.save(item)
        let queue = JugglingResultQueue(root: root)
        let store = SessionHistoryStore(service: nil, queue: queue, library: library)
        store.useAccount(owner)
        store.saveReplayEdit(draft, id: item.id, owner: item.ownerID)
        XCTAssertNil(try library.replayEdit(for: item))
        try queue.markDeleted(item.ownerID!)
        XCTAssertThrowsError(try library.saveReplayEdit(draft, id: item.id, owner: item.ownerID))
    }

    func testPreparedAnalysisSurvivesRelaunchWithoutReadingOriginalOrReprocessing() async throws {
        let item = item(), original = summary()
        try library.saveReplayData(.init(summary: original), for: item)
        try library.saveReplayAnalysis(.init(summary: original, prepared: true), for: item)
        let relaunched = SessionHistoryLibrary(root: library.root)
        let base = try XCTUnwrap(relaunched.replayData(for: item)).summary(item: item, videoURL: original.videoURL)
        let restored = try XCTUnwrap(relaunched.replayAnalysis(for: item)).restoring(base)
        XCTAssertEqual(restored.renderTrack.first?.ballMask?.alpha, original.track.first?.ballMask?.alpha)
        XCTAssertFalse(restored.needsVisualPreparation)
        XCTAssertFalse(restored.visualTrackIsPositionsOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.videoURL.path))
        let ready = try await SessionEffectsPreparation().prepare(restored, for: .init(ballSkin: .arctic))
        XCTAssertEqual(ready.renderTrack.first?.ballMask?.alpha, original.track.first?.ballMask?.alpha)
    }

    func testRawImportMasksAreRetainedButNotClaimedAsFinishedPreparation() throws {
        let original = summary(), item = item()
        try library.saveReplayAnalysis(.init(summary: original, prepared: false), for: item)
        let restored = try XCTUnwrap(library.replayAnalysis(for: item)).restoring(original)
        XCTAssertEqual(restored.renderTrack.first?.ballMask?.alpha, original.track.first?.ballMask?.alpha)
        XCTAssertTrue(restored.needsVisualPreparation)
        XCTAssertFalse(restored.visualTrackIsPositionsOnly)
    }

    func testLateRawSaveCannotReplaceCompletedOriginalFrameRateMasks() throws {
        let item = item(), original = summary()
        try library.saveReplayAnalysis(.init(summary: original, prepared: true), for: item)
        var weaker = original; weaker.visualTrackIsPositionsOnly = true
        try library.saveReplayAnalysis(.init(summary: weaker, prepared: true), for: item)
        try library.saveReplayAnalysis(.init(summary: weaker, prepared: false), for: item)
        let retained = try XCTUnwrap(library.replayAnalysis(for: item))
        XCTAssertTrue(retained.prepared)
        XCTAssertFalse(retained.positionsOnly)
        XCTAssertTrue(retained.everyFrame)
    }

    func testOriginalQualityCannotReuseOnlyCappedSavedFrames() async throws {
        let original = summary()
        var frames = [original.track[0], original.track[0]]
        frames[0].identity = .init(index: 0, time: .zero, width: 1080, height: 1920, coordinates: "composition")
        frames[1].identity = .init(index: 2, time: CMTime(value: 2, timescale: 120), width: 1080, height: 1920, coordinates: "composition")
        var capped = original; capped.visualTrack = frames; capped.needsVisualPreparation = false
        let preparation = SessionEffectsPreparation()
        _ = try await preparation.prepare(capped, for: .init(ballSkin: .arctic))
        do {
            _ = try await preparation.prepare(capped, for: .init(ballSkin: .arctic), everyFrame: true)
            XCTFail("Original-quality export must request missing source frames; the test source does not exist")
        } catch { /* Missing source proves this did not reuse the capped preparation. */ }
    }

    func testDeletingReplayRemovesAnalysisAndSpinAndBlocksLateWrites() throws {
        let item = item(), original = summary()
        let motion = BallSurfaceTimeline(entries: [.init(time: 0, orientation: BallSurfaceTimeline.initial, accepted: true)], elapsed: 0)
        try library.saveReplayAnalysis(.init(summary: original, prepared: true), for: item)
        try library.saveReplayMotion(motion, for: item, key: "track")
        XCTAssertNil(try library.replayMotion(for: item, key: "different-track"))
        try library.removeEditorData(for: item)
        XCTAssertNil(try library.replayAnalysis(for: item))
        XCTAssertNil(try library.replayMotion(for: item, key: "track"))
        XCTAssertThrowsError(try library.saveReplayAnalysis(.init(summary: original, prepared: true), for: item))
        XCTAssertThrowsError(try library.saveReplayMotion(motion, for: item, key: "track"))
    }

    func testImportedHistoryRepairsLegacyRecordingClockFlag() {
        let imported = HistorySession(id: UUID(), ownerID: nil, touches: 2, durationMS: 2000, source: .gallery,
                                      completedAt: Date(), syncState: .deviceOnly)
        var original = summary(); original.framesUseCompositionClock = false
        XCTAssertTrue(HistoryReplayData(summary: original).summary(item: imported, videoURL: original.videoURL).framesUseCompositionClock)
    }

    func testRetainedRealClipReopensOnIPhoneWithoutOriginalOrTransientCache() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Uses the real 4K clip already staged on the iPhone 11")
        #else
        let source = URL.documentsDirectory.appendingPathComponent("ball-export-a13-source.mov")
        let trackURL = URL.documentsDirectory.appendingPathComponent("ball-export-a13-track.plist")
        guard FileManager.default.fileExists(atPath: source.path), FileManager.default.fileExists(atPath: trackURL.path) else {
            throw XCTSkip("Stage the original and its retained track before running the phone benchmark")
        }
        let stored = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: trackURL))
        XCTAssertTrue(StoredFrame.validated(stored))
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let item = HistorySession(id: UUID(), ownerID: nil, touches: 2, durationMS: Int(duration * 1000), source: .gallery,
                                  completedAt: Date(), syncState: .deviceOnly)
        var original = SessionSummary.make(touches: 2, duration: duration, bestCombo: 2, personalBest: 2, videoURL: source,
            touchesMarked: [.init(index: 1, time: 1, x: 0.5, y: 0.5), .init(index: 2, time: 2, x: 0.5, y: 0.5)], track: stored.map(\.frame))
        original.framesUseCompositionClock = true; original.needsVisualPreparation = true
        original.historyReplay = HistoryReplayContext(item: item, library: library)
        let start = ProcessInfo.processInfo.systemUptime
        let ready = try await SessionEffectsPreparation().prepare(original, for: .init(ballSkin: .arctic))
        let motion = try await BallSurfaceTimeline.prepare(source: source, track: BallEffectTrack(frames: ready.renderTrack), history: original.historyReplay)
        let firstPreparation = ProcessInfo.processInfo.systemUptime - start
        try library.saveReplayData(.init(summary: original), for: item)
        let saveStart = ProcessInfo.processInfo.systemUptime
        try library.saveReplayAnalysis(.init(summary: ready, prepared: true), for: item)
        let saveSeconds = ProcessInfo.processInfo.systemUptime - saveStart
        let expected = SessionAnalysisStore.digest(try SessionAnalysisStore.frameData(ready.renderTrack))
        var reopen: [Double] = []
        for _ in 0..<3 {
            let clock = ProcessInfo.processInfo.systemUptime
            let relaunched = SessionHistoryLibrary(root: library.root)
            // A missing path makes a normal inference/spin-cache fallback fail.
            // Only the session-owned artifacts can satisfy this request.
            let absent = root.appendingPathComponent("not-readable-original.mov")
            let base = try XCTUnwrap(relaunched.replayData(for: item)).summary(item: item, videoURL: absent)
            let restored = try XCTUnwrap(relaunched.replayAnalysis(for: item)).restoring(base)
            let reopened = try await SessionEffectsPreparation().prepare(restored, for: .init(ballSkin: .arctic))
            let spin = try await BallSurfaceTimeline.prepare(source: absent, track: BallEffectTrack(frames: reopened.renderTrack), history: original.historyReplay)
            reopen.append(ProcessInfo.processInfo.systemUptime - clock)
            XCTAssertEqual(spin.entries.count, motion.entries.count)
            XCTAssertEqual(SessionAnalysisStore.digest(try SessionAnalysisStore.frameData(reopened.renderTrack)), expected)
        }
        let bytes = try FileManager.default.contentsOfDirectory(at: library.root.appendingPathComponent("guest"), includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let report: [String: Any] = ["source": source.lastPathComponent, "duration": duration, "frames": ready.renderTrack.count,
            "first_preparation_seconds": firstPreparation, "analysis_save_seconds": saveSeconds, "reopen_seconds": reopen,
            "saved_editor_bytes": bytes, "spin_entries": motion.entries.count,
            "scope": "Real retained 4K ball track, normal mask refinement and spin. Reopens load persistent session artifacts with an unreadable source path; no detector, repair, spin computation or transient cache can supply them. Excludes video-player startup and export rendering."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("history-retention-benchmark.json"), options: .atomic)
        #endif
    }

    func testUntimedLegacyOriginalCanBePreparedOnPhysicalPhone() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Full legacy counting needs the physical phone's Vision body/hand models")
        #else
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-sixty", withExtension: "mov"))
        let analyzer = VideoAnalyzer()
        defer { analyzer.cancel() }
        analyzer.analyse(url: source)
        while analyzer.isRunning { try await Task.sleep(for: .milliseconds(150)) }
        XCTAssertEqual(analyzer.status, "done", analyzer.failureDiagnostic)
        XCTAssertFalse(analyzer.recordedTrack.isEmpty)
        let item = item()
        let rebuilt = HistoryReplayData.rebuilt(item: item, videoURL: source, duration: analyzer.videoDuration,
            frames: analyzer.recordedTrack, detectedTouches: analyzer.recordedTouches)
        try library.saveReplayData(.init(summary: rebuilt), for: item)
        let restored = try XCTUnwrap(library.replayData(for: item)).summary(item: item, videoURL: source)
        XCTAssertEqual(restored.touches, item.touches)
        XCTAssertEqual(restored.touchesMarked.map(\.time), analyzer.recordedTouches.map(\.time))
        XCTAssertTrue(restored.needsVisualPreparation)
        #endif
    }
}
