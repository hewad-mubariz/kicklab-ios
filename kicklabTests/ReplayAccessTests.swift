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
        XCTAssertFalse(free.overlays.counter.enabled)
        XCTAssertFalse(free.overlays.graph.enabled)
        XCTAssertFalse(free.showGraph)
        XCTAssertEqual(saved.edit.ballSkin, .chrome)
        XCTAssertTrue(saved.overlays.graph.enabled)
        XCTAssertEqual(saved.overlays.counter.style, .jelly)
        XCTAssertEqual(saved.allowed(isPro: true), saved)
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
            for camera in ShotCameraStyle.allCases {
                let saved = ShotReplayLook(style: trail, intensity: 0.65, graphStyle: .fireworks,
                                           showGraph: true, camera: .init(style: camera))
                let free = saved.allowed(isPro: false)
                XCTAssertEqual(free.style, trail == .none ? .none : .glowTrail)
                XCTAssertEqual(free.intensity, 0.65)
                XCTAssertFalse(free.showGraph)
                XCTAssertEqual(free.camera, ShotCameraSettings())
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
        XCTAssertTrue(ShotReplayLook(style: .glowTrail, showGraph: false, camera: .init(style: .frames)).requiresPro)
    }
}
