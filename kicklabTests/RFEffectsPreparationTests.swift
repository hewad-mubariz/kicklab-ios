import AVFoundation
import XCTest
@testable import kicklab

final class RFEffectsPreparationTests: XCTestCase {
    private func summary(source: URL) -> SessionSummary {
        let frame = RecordedFrame(time: 0.016, x: 0.4, y: 0.6, width: 0.1, height: 0.07, score: 0.93,
            smoothedX: 0.42, smoothedY: 0.58, vy: -0.2, motion: .rising, detected: true,
            person: nil, ballMask: BallMask(rect: CGRect(x: 0.35, y: 0.565, width: 0.1, height: 0.07),
                width: 2, height: 2, alpha: [0, 255, 128, 0]), usesBallMasks: true)
        var value = SessionSummary.make(touches: 7, duration: 2, bestCombo: 7, personalBest: 7, videoURL: source,
            touchesMarked: [.init(index: 1, time: 0.4, x: 0.5, y: 0.6)], track: [frame])
        value.needsVisualPreparation = true; value.framesUseCompositionClock = true
        return value
    }
    @MainActor func testFireWithOriginalBallPreparesOnceAndPreservesLiveCounterForOtherEffects() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let input = summary(source: source), preparation = SessionEffectsPreparation()
        let ready = try await preparation.prepare(input, for: .init(style: .fire, ballSkin: .original))
        XCTAssertFalse(ready.needsVisualPreparation)
        XCTAssertNotNil(ready.visualTrack)
        XCTAssertEqual(ready.touches, input.touches); XCTAssertEqual(ready.touchesMarked, input.touchesMarked)
        XCTAssertEqual(ready.track.map(\.time), input.track.map(\.time))
        XCTAssertEqual(preparation.progress, 1)
        for style in BallStyle.allCases where style != .none {
            let reused = try await preparation.prepare(input, for: .init(style: style, ballSkin: .original))
            XCTAssertFalse(reused.needsVisualPreparation, style.rawValue)
            XCTAssertEqual(reused.touchesMarked, input.touchesMarked)
            XCTAssertEqual(reused.renderTrack.map(\.time), ready.renderTrack.map(\.time))
        }
        let gold = try await preparation.prepare(input, for: .init(style: .none, ballSkin: .gold))
        XCTAssertFalse(gold.needsVisualPreparation)
    }
    @MainActor func testCounterOnlyAndZeroIntensityDoNotReadVideoOrStartPreparation() async throws {
        let input = summary(source: URL(fileURLWithPath: "/missing-\(UUID().uuidString).mov"))
        let preparation = SessionEffectsPreparation()
        for edit in [SessionEditState(style: .none), SessionEditState(style: .fire, intensity: 0)] {
            let ready = try await preparation.prepare(input, for: edit)
            XCTAssertTrue(ready.needsVisualPreparation)
            XCTAssertNil(preparation.prepared); XCTAssertNil(preparation.error)
            XCTAssertFalse(preparation.isPreparing)
            XCTAssertEqual(ready.touchesMarked, input.touchesMarked)
        }
    }
    @MainActor func testFailedFirePreparationIsNotMarkedReadyAndCanRecoverOnValidSource() async throws {
        let preparation = SessionEffectsPreparation()
        let missing = summary(source: URL(fileURLWithPath: "/missing-\(UUID().uuidString).mov"))
        do {
            _ = try await preparation.prepare(missing, for: .init(style: .fire))
            XCTFail("Fire must request visual preparation even with the original ball")
        } catch { }
        XCTAssertNil(preparation.prepared); XCTAssertFalse(preparation.isPreparing); XCTAssertNotNil(preparation.error)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-mask-vfr", withExtension: "mov"))
        let ready = try await preparation.prepare(summary(source: source), for: .init(style: .fire))
        XCTAssertFalse(ready.needsVisualPreparation); XCTAssertNil(preparation.error)
    }
}
