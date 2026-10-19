#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallRecoveryTests: XCTestCase {
    private let size = CGSize(width: 1280, height: 720)
    private let corners = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                           CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]

    func testUnchangedBoardRecoversWithThreeTightFreshChecks() {
        var a = WallBoardAlignment(corners: corners)
        for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
        let epoch = a.update.evidenceEpoch
        a.observe(nil, at: 0.45, size: size)
        XCTAssertTrue(a.shouldCheck(at: 0.51))
        XCTAssertFalse(a.shouldCheck(at: 0.48))
        for t in [0.51, 0.56] {
            a.observe(corners, at: t, size: size)
            XCTAssertFalse(a.canScore(at: t))
        }
        a.observe(corners, at: 0.61, size: size)
        XCTAssertTrue(a.canScore(at: 0.61))
        XCTAssertEqual(a.update.evidenceEpoch, epoch)
        XCTAssertEqual(a.update.corners, corners)
    }

    func testFastRecoveryRejectsLooseGeometryAndTooCloselySpacedChecks() {
        for scenario in ["loose", "burst", "missing", "expired"] {
            var a = WallBoardAlignment(corners: corners)
            for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
            let epoch = a.update.evidenceEpoch
            a.observe(nil, at: 0.45, size: size)
            var measured = corners
            if scenario == "loose" { measured[0].x += 2 / size.width }
            let times = scenario == "burst" ? [0.50, 0.51, 0.52]
                : scenario == "expired" ? [1.31, 1.36, 1.41] : [0.51, 0.56, 0.61]
            for (i, t) in times.enumerated() {
                a.observe(scenario == "missing" && i == 1 ? nil : measured, at: t, size: size)
                XCTAssertFalse(a.canScore(at: t), scenario)
            }
            if scenario == "expired" { XCTAssertGreaterThan(a.update.evidenceEpoch, epoch) }
        }
    }

    func testRapidRecoveryChecksDoNotTurnTransientCornerNoiseIntoMovement() {
        var a = WallBoardAlignment(corners: corners)
        for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
        let epoch = a.update.evidenceEpoch
        var jump = corners; jump[0].x += 12 / size.width
        for t in [0.45, 0.51, 0.56] {
            a.observe(jump, at: t, size: size)
            XCTAssertEqual(a.update.evidenceEpoch, epoch)
            XCTAssertFalse(a.canScore(at: t))
        }
        for t in [0.61, 0.66, 0.71] { a.observe(corners, at: t, size: size) }
        XCTAssertTrue(a.canScore(at: 0.71))
        XCTAssertEqual(a.update.evidenceEpoch, epoch)
    }

    func testEarlyContactWaitsForReboundThenScoreWaitsForAlignment() {
        for fps in [30.0, 60.0] {
            var shots = WallAlignedShotTracker()
            var previewTime: Double?, scoreTime: Double?
            for frame in 0..<Int(fps * 2) {
                let t = Double(frame) / fps
                let ready = t >= 1.7
                let found = shots.process(.init(t: t, x: 600, y: 210, d: 44 + abs(t - 1) * 120, hand: .clear),
                    at: t, update: .init(status: ready ? .ready : .obscured, corners: corners, revision: 1),
                    retainEvidence: true, canScore: ready,
                    reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), size: size, fps: fps)
                if shots.contactPreview != nil, previewTime == nil { previewTime = t }
                if !found.isEmpty {
                    scoreTime = t
                    XCTAssertNil(shots.contactPreview)
                    XCTAssertEqual(found.map(\.box), [2])
                }
                if !ready { XCTAssertTrue(found.isEmpty) }
            }
            XCTAssertNotNil(previewTime)
            XCTAssertGreaterThan(previewTime ?? 0, 1.18)
            XCTAssertLessThan(previewTime ?? 10, 1.35)
            XCTAssertEqual(scoreTime ?? 0, 1.7, accuracy: 0.04)
        }
    }

    func testPreviewCannotSurviveMovementOrLossAndNeverAcknowledgesHeldBall() {
        for scenario in ["movement", "loss", "held", "unknown"] {
            var shots = WallAlignedShotTracker()
            var previewSeen = false
            for frame in 0..<120 {
                let t = Double(frame) / 60
                let invalid = t >= 1.3
                let hand: WallHandState = scenario == "held" ? .held : scenario == "unknown" ? .unknown : .clear
                let found = shots.process(.init(t: t, x: 600, y: 210, d: 44 + abs(t - 1) * 120, hand: hand),
                    at: t, update: .init(status: .obscured, corners: corners, revision: 1,
                                        evidenceEpoch: scenario == "movement" && invalid ? 2 : 1),
                    retainEvidence: !(scenario == "loss" && invalid), canScore: false,
                    reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), size: size, fps: 60)
                previewSeen = previewSeen || shots.contactPreview != nil
                if invalid { XCTAssertNil(shots.contactPreview, scenario) }
                XCTAssertTrue(found.isEmpty)
            }
            XCTAssertEqual(previewSeen, scenario == "movement" || scenario == "loss", scenario)
        }
    }

    func testProbingContactDoesNotConsumeFinalEvidenceOrDecisions() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
                              bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        var baseline = WallImpactDetector(board: board,
            reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), imageWidth: 1280)
        var probed = baseline
        for frame in 0..<120 {
            let t = Double(frame) / 60
            let o = WallImpactDetector.Observation(t: t, x: 600, y: 210, d: 44 + abs(t - 1) * 120, hand: .clear)
            baseline.add(o); probed.add(o)
            _ = probed.previewContacts(now: t)
            XCTAssertEqual(probed.impacts(now: t), baseline.impacts(now: t))
            XCTAssertEqual(probed.takeDecisions().map(\.reason), baseline.takeDecisions().map(\.reason))
        }
    }

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

    func testSingleCornerJumpWaitsForAllFourOriginalMarkersWithoutChangingGeometry() {
        for corner in 0..<4 {
            var a = WallBoardAlignment(corners: corners)
            for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
            let epoch = a.update.evidenceEpoch
            var suspect = corners
            suspect[corner].y += 12 / size.height
            a.observe(suspect, at: 0.45, size: size)
            XCTAssertEqual(a.update.status, .obscured)
            XCTAssertFalse(a.canScore(at: 0.45))
            XCTAssertTrue(a.canRetainEvidence(at: 0.45))
            XCTAssertEqual(a.update.corners, corners)
            for t in [0.6, 0.75] {
                a.observe(corners, at: t, size: size)
                XCTAssertFalse(a.canScore(at: t))
            }
            a.observe(corners, at: 0.9, size: size)
            XCTAssertTrue(a.canScore(at: 0.9))
            XCTAssertEqual(a.update.evidenceEpoch, epoch)
            XCTAssertEqual(a.update.corners, corners)
        }
    }

    func testPersistentSingleCornerMovementAndMultiCornerMovementDiscardShots() {
        for count in [1, 2, 4] {
            var a = WallBoardAlignment(corners: corners)
            for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
            let epoch = a.update.evidenceEpoch
            var moved = corners
            for i in 0..<count { moved[i].y += 12 / size.height }
            a.observe(moved, at: 0.45, size: size)
            XCTAssertFalse(a.canScore(at: 0.45))
            if count > 1 {
                XCTAssertFalse(a.canRetainEvidence(at: 0.45))
                XCTAssertGreaterThan(a.update.evidenceEpoch, epoch)
            }
            a.observe(moved, at: 0.6, size: size)
            XCTAssertFalse(a.canScore(at: 0.6))
            XCTAssertFalse(a.canRetainEvidence(at: 0.6))
            XCTAssertGreaterThan(a.update.evidenceEpoch, epoch)
            for t in [0.75, 0.9] { a.observe(moved, at: t, size: size) }
            XCTAssertTrue(a.canScore(at: 0.9))
            XCTAssertEqual(a.update.corners, moved)
        }
    }

    func testCornerJumpsCannotExtendLossDeadlineOrBridgeAProcessingStall() {
        for scenario in ["repeated", "stall", "duringRevalidation"] {
            var a = WallBoardAlignment(corners: corners)
            for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
            let epoch = a.update.evidenceEpoch
            var suspect = corners
            suspect[0].x += 12 / size.width
            if scenario == "stall" {
                a.observe(suspect, at: 0.7, size: size)
                XCTAssertFalse(a.canRetainEvidence(at: 0.7))
            } else {
                for (i, t) in [0.45, 0.6, 0.75, 0.9, 1.05].enumerated() {
                    a.observe(i.isMultiple(of: 2) ? suspect : nil, at: t, size: size)
                    XCTAssertFalse(a.canScore(at: t))
                }
                a.observe(scenario == "duringRevalidation" ? corners : nil, at: 1.2, size: size)
                a.observe(suspect, at: 1.35, size: size)
                XCTAssertFalse(a.canRetainEvidence(at: 1.35))
            }
            XCTAssertGreaterThan(a.update.evidenceEpoch, epoch, scenario)
        }
    }

    func testCornerJumpCanRecoverReleasedShotButNotHeldBallOrCameraMovement() {
        for scenario in ["transient", "persistent", "coherent", "held"] {
            var alignment = WallBoardAlignment(corners: corners)
            for t in [-0.45, -0.3, -0.15] { alignment.observe(corners, at: t, size: size) }
            var shots = WallAlignedShotTracker()
            var found: [WallImpactDetector.Impact] = []
            for frame in 0..<110 {
                let t = Double(frame) / 60
                if frame.isMultiple(of: 9) {
                    var measured = corners
                    if frame == 27 || (scenario == "persistent" && frame >= 27) {
                        measured[0].x += 12 / size.width
                    }
                    if scenario == "coherent", frame >= 27 {
                        measured = corners.map { CGPoint(x: $0.x + 12 / size.width, y: $0.y) }
                    }
                    alignment.observe(measured, at: t, size: size)
                }
                let o = WallImpactDetector.Observation(t: t, x: 600, y: 210,
                    d: 44 + abs(Double(frame - 35)) * 2, hand: scenario == "held" ? .held : .clear)
                let hits = shots.process(o, at: t, update: alignment.update,
                    retainEvidence: alignment.canRetainEvidence(at: t), canScore: alignment.canScore(at: t),
                    reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), size: size, fps: 60)
                if !alignment.canScore(at: t) { XCTAssertTrue(hits.isEmpty) }
                found += hits
            }
            XCTAssertEqual(found.count, scenario == "transient" ? 1 : 0, scenario)
            if scenario == "transient" { XCTAssertEqual(found.first?.box, 2) }
        }
    }

    func testBoardReturningBeforeLossDeadlineCanFinishRevalidation() {
        var a = WallBoardAlignment(corners: corners)
        for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
        let epoch = a.update.evidenceEpoch
        for t in [0.45, 0.6, 0.75, 0.9, 1.05] { a.observe(nil, at: t, size: size) }
        for t in [1.2, 1.35] {
            a.observe(corners, at: t, size: size)
            XCTAssertTrue(a.canRetainEvidence(at: t))
            XCTAssertFalse(a.canScore(at: t))
        }
        XCTAssertTrue(a.canRetainEvidence(at: 1.45))
        a.observe(corners, at: 1.5, size: size)
        XCTAssertTrue(a.canScore(at: 1.5))
        XCTAssertEqual(a.update.evidenceEpoch, epoch)
        XCTAssertEqual(a.update.corners, corners)
    }

    func testRevalidationAllowanceCannotSurviveNewLossMovementOrStalledFrames() {
        for scenario in ["hiddenAgain", "moved", "stalled", "lateReturn"] {
            var a = WallBoardAlignment(corners: corners)
            for t in [0.0, 0.15, 0.3] { a.observe(corners, at: t, size: size) }
            let epoch = a.update.evidenceEpoch
            for t in [0.45, 0.6, 0.75, 0.9, 1.05] { a.observe(nil, at: t, size: size) }
            a.observe(scenario == "lateReturn" ? nil : corners, at: 1.2, size: size)
            let time = scenario == "stalled" ? 1.55 : 1.35
            let points = scenario == "moved" ? corners.map { CGPoint(x: $0.x + 0.03, y: $0.y) } : corners
            a.observe(scenario == "hiddenAgain" ? nil : points, at: time, size: size)
            XCTAssertFalse(a.canScore(at: time), scenario)
            XCTAssertFalse(a.canRetainEvidence(at: time), scenario)
            XCTAssertGreaterThan(a.update.evidenceEpoch, epoch, scenario)
        }
    }

    /// A real approach/rebound sequence crosses the marker dropout. It must
    /// score once after revalidation, and never after movement or a long loss.
    func testShotAcrossOcclusionIsDeferredAndNeverCrossesDriftOrExpiry() {
        for scenario in ["brief", "revalidating", "moved", "long", "held", "heldRevalidating", "movedRevalidating"] {
            var alignment = WallBoardAlignment(corners: corners)
            for t in [-0.45, -0.3, -0.15] { alignment.observe(corners, at: t, size: size) }
            var shots = WallAlignedShotTracker()
            var found: [WallImpactDetector.Impact] = []
            var reported: [Double] = []
            for frame in 0..<110 {
                let t = Double(frame) / 60
                if frame.isMultiple(of: 9) {
                    let slowReturn = ["revalidating", "heldRevalidating", "movedRevalidating"].contains(scenario)
                    let obscured = t >= 0.45 && t < (scenario == "long" ? 1.5 : (slowReturn ? 1.2 : 0.75))
                    let moved = (scenario == "moved" && t >= 0.75) || (scenario == "movedRevalidating" && t >= 1.35)
                    let p = moved ? corners.map { CGPoint(x: $0.x + 0.03, y: $0.y) } : corners
                    alignment.observe(obscured ? nil : p, at: t, size: size)
                }
                let o = WallImpactDetector.Observation(t: t, x: 600, y: 210,
                    d: 44 + abs(Double(frame - 35)) * 2, hand: scenario.hasPrefix("held") ? .held : .clear)
                let hits = shots.process(o, at: t, update: alignment.update,
                    retainEvidence: alignment.canRetainEvidence(at: t), canScore: alignment.canScore(at: t),
                    reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), size: size, fps: 60)
                if !alignment.canScore(at: t) { XCTAssertTrue(hits.isEmpty) }
                reported += hits.map { _ in t }; found += hits
            }
            let shouldRecover = ["brief", "revalidating"].contains(scenario)
            XCTAssertEqual(found.count, shouldRecover ? 1 : 0, scenario)
            if shouldRecover {
                XCTAssertGreaterThanOrEqual(reported.first ?? 0, scenario == "brief" ? 1.05 : 1.5)
                XCTAssertEqual(found.first?.box, 2)
            }
        }
    }

    func testTimerRunsWithoutHitAndExplicitlyPausesForAlignment() {
        let m = WallTargetsModel(defaults: UserDefaults(suiteName: "WallRecovery.\(UUID())")!)
        let start = Date(timeIntervalSince1970: 100)
        m.setCorners(corners); m.validateMappingForTest(); m.finishReference(Array(repeating: 0.04, count: 6))
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

    func testRecordedTargetSixRecoversOnlyAfterUnchangedCornersReturn() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-revalidation-target-six.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let seed = (fixture["seed"] as! [[Double]]).map { CGPoint(x: $0[0], y: $0[1]) }
        let reference = try XCTUnwrap(WallBallReference(fixture["reference"] as! [Double]))
        for scenario in ["unchanged", "moved", "late"] {
            var alignment = WallBoardAlignment(corners: seed, referenceCorners: seed)
            var shots = WallAlignedShotTracker()
            var found: [WallImpactDetector.Impact] = [], reported: [Double] = []
            for row in fixture["frames"] as! [[String: Any]] {
                let t = row["t"] as! Double
                if row["checked"] as! Bool {
                    var measured = (row["measured"] as? [[Double]])?.map { CGPoint(x: $0[0], y: $0[1]) }
                    if scenario == "moved", t >= 199.13 {
                        measured = measured?.map { CGPoint(x: $0.x + 0.02, y: $0.y) }
                    }
                    if scenario == "late", t >= 199.13, t < 199.29 { measured = nil }
                    alignment.observe(measured, at: t, size: size)
                }
                let o = (row["ball"] as? [Double]).map {
                    WallImpactDetector.Observation(t: t, x: $0[0], y: $0[1], d: $0[2],
                        hand: WallHandState(rawValue: Int($0[3])) ?? .unknown)
                }
                let hits = shots.process(o, at: t, update: alignment.update,
                    retainEvidence: alignment.canRetainEvidence(at: t), canScore: alignment.canScore(at: t),
                    reference: reference, size: size, fps: row["fps"] as! Double)
                if !alignment.canScore(at: t) { XCTAssertTrue(hits.isEmpty) }
                found += hits; reported += hits.map { _ in t }
            }
            XCTAssertEqual(found.count, scenario == "unchanged" ? 1 : 0, scenario)
            if scenario == "unchanged" {
                XCTAssertEqual(found.first?.box, 6)
                XCTAssertEqual(try XCTUnwrap(found.first).t, 198.56364, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(reported.first), 199.49687, accuracy: 0.001)
            }
        }
    }

    func testRecordedCornerJumpMissesRecoverWithoutAcceptingMovementHeldBallsOrLongLoss() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-isolated-corner-jumps.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let reference = try XCTUnwrap(WallBallReference(fixture["reference"] as! [Double]))
        for sample in fixture["cases"] as! [[String: Any]] {
            let contact = sample["candidateTime"] as! Double
            let seed = (sample["seed"] as! [[Double]]).map { CGPoint(x: $0[0], y: $0[1]) }
            for scenario in ["recorded", "moved", "held"] {
                var alignment = WallBoardAlignment(corners: seed, referenceCorners: seed)
                var shots = WallAlignedShotTracker()
                var found: [WallImpactDetector.Impact] = []
                for row in sample["frames"] as! [[String: Any]] {
                    let t = row["t"] as! Double
                    if row["checked"] as! Bool {
                        var measured = (row["measured"] as? [[Double]])?.map { CGPoint(x: $0[0], y: $0[1]) }
                        if scenario == "moved", t >= contact {
                            measured = measured?.map { CGPoint(x: $0.x + 0.02, y: $0.y) }
                        }
                        alignment.observe(measured, at: t, size: size)
                    }
                    let o = (row["ball"] as? [Double]).map {
                        WallImpactDetector.Observation(t: t, x: $0[0], y: $0[1], d: $0[2],
                            hand: scenario == "held" ? .held : (WallHandState(rawValue: Int($0[3])) ?? .unknown))
                    }
                    let hits = shots.process(o, at: t, update: alignment.update,
                        retainEvidence: alignment.canRetainEvidence(at: t), canScore: alignment.canScore(at: t),
                        reference: reference, size: size, fps: row["fps"] as! Double)
                    if !alignment.canScore(at: t) { XCTAssertTrue(hits.isEmpty) }
                    found += hits.filter { abs($0.t - contact) < 0.01 }
                }
                let expected = scenario == "recorded" && sample["shouldRecover"] as! Bool
                XCTAssertEqual(found.count, expected ? 1 : 0, "\(contact) \(scenario)")
                if expected { XCTAssertEqual(found.first?.box, sample["target"] as? Int) }
            }
        }
    }
}
#endif
