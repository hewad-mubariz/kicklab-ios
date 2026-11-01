import CoreMedia
import XCTest
@testable import kicklab

/// Imports of 50 fps and faster are counted at the live camera's 30 fps. Effects keep those
/// counted positions; a replacement ball still gets a silhouette from every source frame.
final class ImportFrameRateTests: XCTestCase {
    private func frame(source index: Int, fps: Double, recovery: Bool = false) -> RecordedFrame {
        RecordedFrame(time: Double(index) / fps, x: 0.5, y: 0.5, width: 0.1, height: 0.1, score: 0.9,
            smoothedX: 0.5, smoothedY: 0.5, vy: 0, motion: .unknown, detected: true, person: nil,
            isVisualRecovery: recovery,
            identity: RecordedFrameIdentity(index: index, time: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
                width: 720, height: 1280, coordinates: "composition-720-sdr-v1"))
    }

    func testCountedTracksAreToldApartFromDenseOnes() {
        XCTAssertTrue(BallVisualRefiner.analysedEveryFrame((0..<8).map { frame(source: $0, fps: 120) }))
        // A miss leaves a gap, but neighbouring frames elsewhere still show every frame was read.
        XCTAssertTrue(BallVisualRefiner.analysedEveryFrame([0, 1, 5, 6].map { frame(source: $0, fps: 120) }))
        XCTAssertFalse(BallVisualRefiner.analysedEveryFrame(stride(from: 0, to: 40, by: 4).map { frame(source: $0, fps: 120) }))
        // A visual recovery shares its frame with the observation and is not a second reading.
        XCTAssertFalse(BallVisualRefiner.analysedEveryFrame([frame(source: 0, fps: 60), frame(source: 0, fps: 60, recovery: true),
                                                            frame(source: 2, fps: 60), frame(source: 4, fps: 60)]))
        // Saved sessions without identities keep their full-rate preparation.
        let legacy = (0..<4).map { RecordedFrame(time: Double($0) / 30, x: 0.5, y: 0.5, width: 0.1, height: 0.1, score: 0.9,
            smoothedX: 0.5, smoothedY: 0.5, vy: 0, motion: .unknown, detected: true, person: nil) }
        XCTAssertTrue(BallVisualRefiner.analysedEveryFrame(legacy))
    }

    func testOnlyFastClipsAreCountedAtThirtyFramesPerSecond() {
        XCTAssertFalse(VideoProcessingInfo(size: CGSize(width: 1080, height: 1920), fps: 30, duration: 20).highFrameRate)
        XCTAssertTrue(VideoProcessingInfo(size: CGSize(width: 1080, height: 1920), fps: 59.94, duration: 20).highFrameRate)
        XCTAssertTrue(VideoProcessingInfo(size: CGSize(width: 2160, height: 3840), fps: 119.94, duration: 20).highFrameRate)
        XCTAssertEqual(VideoAnalyzer.countingSpacing, 0.03)
    }

    @MainActor
    func testEffectsKeepCountedPositionsAndAReplacementBallReadsEveryFrame() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-sixty", withExtension: "mov"))
        let every = try await VideoAnalyzer.replayTrack(source: source)
        XCTAssertEqual(every.count, 90)
        // What a 30 fps count of this 60 fps clip observes: every second source frame.
        let counted = every.filter { ($0.identity?.index ?? 1) % 2 == 0 }
        XCTAssertEqual(counted.count, 45)
        var summary = SessionSummary.make(touches: 0, duration: 1.5, bestCombo: 0, personalBest: 0,
                                          videoURL: source, touchesMarked: [], track: counted)
        summary.framesUseCompositionClock = true
        summary.needsVisualPreparation = true
        let preparation = SessionEffectsPreparation()

        let fire = try await preparation.prepare(summary, for: SessionEditState(style: .fire, intensity: 0.8))
        XCTAssertTrue(fire.visualTrackIsPositionsOnly, "Effects follow the counted positions")
        XCTAssertEqual(fire.renderTrack.map(\.time), counted.map(\.time))

        let lava = try await preparation.prepare(summary, for: SessionEditState(style: .fire, intensity: 0.8, ballSkin: .lava))
        XCTAssertFalse(lava.visualTrackIsPositionsOnly)
        let observed = lava.renderTrack.filter { !$0.isVisualMaskRepair && !$0.isVisualRecovery }
        XCTAssertEqual(observed.count, 90, "A replacement ball needs a silhouette on every source frame")
        let track = BallEffectTrack(frames: lava.renderTrack)
        for index in 0..<90 { XCTAssertNotNil(track.mask(at: Double(index) / 60), "frame \(index)") }
    }
}
