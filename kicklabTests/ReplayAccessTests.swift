import XCTest
@testable import kicklab

final class ReplayAccessTests: XCTestCase {
    func testFreeJugglingRemovesPaidLookWithoutMutatingSavedPreferences() {
        var overlays = ExportOverlaySettings()
        overlays.counter.style = .jelly
        overlays.graph.enabled = true
        overlays.graph.style = .comet
        let saved = JugglingReplayLook(edit: .init(style: .fire, ballSkin: .chrome, environment: .night),
                                       overlays: overlays, showGraph: true)
        let free = saved.allowed(isPro: false)
        XCTAssertFalse(free.requiresPro)
        XCTAssertFalse(free.edit.isEdited)
        XCTAssertTrue(free.overlays.counter.enabled)
        XCTAssertEqual(free.overlays.counter.style, .normal)
        XCTAssertEqual(free.overlays.counter.placement, saved.overlays.counter.placement)
        XCTAssertFalse(free.overlays.graph.enabled)
        XCTAssertFalse(free.showGraph)
        XCTAssertEqual(saved.edit.ballSkin, .chrome)
        XCTAssertTrue(saved.overlays.graph.enabled)
        XCTAssertEqual(saved.overlays.counter.style, .jelly)
        XCTAssertEqual(saved.allowed(isPro: true), saved)
    }

    func testNormalCounterIsFreeAndPremiumStylesFallBackWithoutChangingVisibilityOrPlacement() {
        for style in ExportBadgeStyle.allCases {
            for enabled in [false, true] {
                var overlays = ExportOverlaySettings()
                overlays.counter = .init(enabled: enabled, style: style,
                    placement: .init(x: 0.8, y: 0.3, scale: 1.2, rotation: 20))
                let saved = JugglingReplayLook(edit: .init(style: .none), overlays: overlays, showGraph: false)
                XCTAssertEqual(saved.requiresPro, enabled && style != .normal)
                let free = saved.allowed(isPro: false)
                XCTAssertEqual(free.overlays.counter.enabled, enabled)
                XCTAssertEqual(free.overlays.counter.style, .normal)
                XCTAssertEqual(free.overlays.counter.placement, overlays.counter.placement)
                XCTAssertFalse(free.requiresPro)
                XCTAssertEqual(saved.allowed(isPro: true), saved)
            }
        }
    }

    func testTimerIsFreeAndRemainsOptionalAfterProExpires() {
        for enabled in [false, true] {
            var overlays = ExportOverlaySettings()
            overlays.showTimer = enabled
            let saved = JugglingReplayLook(edit: .init(style: .none), overlays: overlays, showGraph: false)
            XCTAssertFalse(saved.requiresPro)
            XCTAssertEqual(saved.allowed(isPro: false).overlays.showTimer, enabled)
            XCTAssertEqual(saved.allowed(isPro: true), saved)
        }
    }

    func testEveryJugglingEffectAndBallIsRemovedFromFreePlaybackAndExport() {
        for effect in BallStyle.selectableCases {
            for ball in BallSkin.allCases {
                let look = JugglingReplayLook(edit: .init(style: effect, ballSkin: ball),
                                              overlays: .init(), showGraph: true)
                XCTAssertFalse(look.allowed(isPro: false).requiresPro, "\(effect) / \(ball)")
                XCTAssertEqual(look.allowed(isPro: true), look)
            }
        }
    }

    func testFreeShotKeepsOnlyNoneOrGlowTrailAndRemovesAllCameraAndGraphTreatments() {
        for trail in ShotTrailStyle.allCases {
            for move in ShotCameraMove.allCases {
                let saved = ShotReplayLook(style: trail, intensity: 0.65, graphStyle: .fireworks,
                                           showGraph: true, camera: ShotCameraTrack(clips: [ShotCameraClip(move: move, start: 0.2, end: 0.9)]))
                let free = saved.allowed(isPro: false)
                XCTAssertEqual(free.style, trail == .none ? .none : .glowTrail)
                XCTAssertEqual(free.intensity, 0.65)
                XCTAssertFalse(free.showGraph)
                XCTAssertEqual(free.camera, ShotCameraTrack())
                XCTAssertFalse(free.requiresPro)
                XCTAssertEqual(saved.allowed(isPro: true), saved)
            }
        }
    }

    func testPaidShotSelectionsRequireUnlockBeforeApplication() {
        XCTAssertFalse(ShotReplayLook(style: .glowTrail, showGraph: false).requiresPro)
        XCTAssertFalse(ShotReplayLook(style: .none, showGraph: false).requiresPro)
        XCTAssertTrue(ShotReplayLook(style: .blueJet, showGraph: false).requiresPro)
        XCTAssertTrue(ShotReplayLook(style: .glowTrail, showGraph: true).requiresPro)
        XCTAssertTrue(ShotReplayLook(style: .glowTrail, showGraph: false,
                                     camera: ShotCameraTrack(clips: [ShotCameraClip(move: .tilt, start: 0, end: 0.5)])).requiresPro)
    }
}
