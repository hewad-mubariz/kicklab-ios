#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallRecoveryTests: XCTestCase {
    private let size = CGSize(width: 1280, height: 720)
    private let corners = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                           CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]

    func testFocusWaitsForStartupThenStableLensAndFreshFrames() {
        var focus = WallFocusReadiness(started: 0)
        for i in 0..<8 {
            let t = Double(i) / 10
            XCTAssertFalse(focus.observe(at: t, frameTime: t, adjusting: false, lens: 0.5))
        }
        XCTAssertFalse(focus.observe(at: 0.8, frameTime: 0.8, adjusting: true, lens: 0.6))
        for i in 9...12 {
            let t = Double(i) / 10
            XCTAssertFalse(focus.observe(at: t, frameTime: t, adjusting: false, lens: 0.6))
        }
        XCTAssertTrue(focus.observe(at: 1.4, frameTime: 1.4, adjusting: false, lens: 0.6))
        XCTAssertFalse(focus.observe(at: 1.5, frameTime: 1.0, adjusting: false, lens: 0.6))
    }

    func testFocusRejectsSlowLensDriftAndStalledPolling() {
        var focus = WallFocusReadiness(started: 0)
        for i in 0...30 {
            let t = Double(i) / 10
            XCTAssertFalse(focus.observe(at: t, frameTime: t, adjusting: false, lens: 0.2 + Double(i) * 0.002))
        }
        XCTAssertFalse(focus.observe(at: 4, frameTime: 4, adjusting: false, lens: 0.26))
    }

    func testBriefOcclusionKeepsEpochButRequiresThreeChecksBeforeScore() {
        var a = WallBoardAlignment(corners: corners)
        for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
        let epoch = a.update.evidenceEpoch
        a.observe(nil, at: 0.45, size: size)
        XCTAssertTrue(a.canRetainEvidence(at: 0.5))
        XCTAssertFalse(a.canScore(at: 0.5))
        for t in [0.6, 0.75] { a.observe(corners, at: t, size: size); XCTAssertFalse(a.canScore(at: t)) }
        a.observe(corners, at: 0.9, size: size)
        XCTAssertTrue(a.canScore(at: 0.9))
        XCTAssertEqual(a.update.evidenceEpoch, epoch)
        XCTAssertEqual(a.update.corners, corners)
    }

    func testLongLossAndCameraShiftBreakEvidenceContinuity() {
        for move in [false, true] {
            var a = WallBoardAlignment(corners: corners)
            for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
            let epoch = a.update.evidenceEpoch
            a.observe(nil, at: 0.45, size: size)
            if move {
                a.observe(corners.map { CGPoint(x: $0.x, y: $0.y - 0.04) }, at: 0.6, size: size)
                XCTAssertEqual(a.update.status, .shifted)
                XCTAssertFalse(a.canRetainEvidence(at: 0.6))
            } else {
                XCTAssertFalse(a.canRetainEvidence(at: 1.26))
                a.observe(nil, at: 1.26, size: size)
            }
            XCTAssertGreaterThan(a.update.evidenceEpoch, epoch)
        }
    }

    /// A real approach/rebound sequence crosses the marker dropout. It must
    /// score once after revalidation, and never after movement or a long loss.
    func testShotAcrossOcclusionIsDeferredAndNeverCrossesDriftOrExpiry() {
        for scenario in ["brief", "moved", "long", "held"] {
            var alignment = WallBoardAlignment(corners: corners)
            for t in [-0.45, -0.3, -0.15] { alignment.observe(corners, at: t, size: size) }
            var shots = WallAlignedShotTracker()
            var found: [WallImpactDetector.Impact] = []
            var reported: [Double] = []
            for frame in 0..<110 {
                let t = Double(frame) / 60
                if frame.isMultiple(of: 9) {
                    let obscured = t >= 0.45 && t < (scenario == "long" ? 1.5 : 0.75)
                    let p = scenario == "moved" && t >= 0.75 ? corners.map { CGPoint(x: $0.x + 0.03, y: $0.y) } : corners
                    alignment.observe(obscured ? nil : p, at: t, size: size)
                }
                let o = WallImpactDetector.Observation(t: t, x: 600, y: 210,
                    d: 44 + abs(Double(frame - 35)) * 2, hand: scenario == "held" ? .held : .clear)
                let hits = shots.process(o, at: t, update: alignment.update,
                    retainEvidence: alignment.canRetainEvidence(at: t), canScore: alignment.canScore(at: t),
                    reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), size: size, fps: 60)
                if !alignment.canScore(at: t) { XCTAssertTrue(hits.isEmpty) }
                reported += hits.map { _ in t }; found += hits
            }
            XCTAssertEqual(found.count, scenario == "brief" ? 1 : 0, scenario)
            if scenario == "brief" { XCTAssertGreaterThanOrEqual(reported.first ?? 0, 1.05); XCTAssertEqual(found.first?.box, 2) }
        }
    }

    func testTimerRunsWithoutHitAndExplicitlyPausesForAlignment() {
        let m = WallTargetsModel(defaults: UserDefaults(suiteName: "WallRecovery.\(UUID())")!)
        let start = Date(timeIntervalSince1970: 100)
        m.setCorners(corners); m.finishReference(Array(repeating: 0.04, count: 6))
        XCTAssertTrue(m.startPlay(at: start))
        XCTAssertEqual(m.timerStatus, "LIVE")
        XCTAssertEqual(m.elapsed(at: start.addingTimeInterval(5)), 5)
        XCTAssertTrue(m.hits.isEmpty)
        m.applyAlignment(.init(status: .obscured, corners: corners, revision: 2), at: start.addingTimeInterval(5))
        XCTAssertEqual(m.timerStatus, "PAUSED")
        XCTAssertEqual(m.elapsed(at: start.addingTimeInterval(7)), 5)
        m.applyAlignment(.init(status: .ready, corners: corners, revision: 3), at: start.addingTimeInterval(7))
        XCTAssertEqual(m.timerStatus, "LIVE")
        XCTAssertEqual(m.elapsed(at: start.addingTimeInterval(8)), 6)
    }
}
#endif
