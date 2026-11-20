#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallFollowTrackingTests: XCTestCase {
    func testRecordedProjectedCircleReleasesTheRealBallOnTheRight() throws {
        struct Fixture: Decodable {
            struct Frame: Decodable { let t: Double; let candidates: [[Double]] }
            let size: [Double], realBallFrame: Double, realBallCentre: [Double], frames: [Frame]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-projected-circle-candidates.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let size = CGSize(width: fixture.size[0], height: fixture.size[1])
        for enabled in [false, true] {
            var tracker = WallBallTracker()
            var selectedAtContact: Detection?
            for frame in fixture.frames {
                let candidates = frame.candidates.map {
                    Detection(score: $0[0], x: $0[1] / size.width, y: $0[2] / size.height,
                              width: $0[3] / size.width, height: $0[4] / size.height)
                }
                let selected = tracker.select(candidates, at: frame.t, size: size,
                                              allowStationaryReacquisition: enabled)
                if abs(frame.t - fixture.realBallFrame) < 0.001 { selectedAtContact = selected }
                tracker.accept(selected, at: frame.t)
            }
            let ball = try XCTUnwrap(selectedAtContact)
            if enabled {
                XCTAssertEqual(ball.x * size.width, fixture.realBallCentre[0], accuracy: 0.01)
                XCTAssertEqual(ball.y * size.height, fixture.realBallCentre[1], accuracy: 0.01)
            } else {
                // Before the fix, the same RF candidates stay attached to the projected O.
                XCTAssertEqual(ball.x * size.width, 669.575, accuracy: 1)
                XCTAssertEqual(ball.y * size.height, 383.445, accuracy: 1)
            }
        }
    }

    func testStationaryReacquisitionPreservesMovingStrongAndSetupTracks() throws {
        let size = CGSize(width: 1280, height: 720)
        func ball(_ x: Double, _ score: Double = 0.22) -> Detection {
            .init(score: score, x: x / 1280, y: 380.0 / 720, width: 70.0 / 1280, height: 75.0 / 720)
        }
        for mode in ["weak_static", "strong_static", "moving", "too_brief", "setup"] {
            var tracker = WallBallTracker()
            let count = mode == "too_brief" ? 4 : 14
            for i in 0..<count {
                tracker.accept(ball(mode == "moving" ? 500 + Double(i) * 8 : 669,
                                    mode == "strong_static" ? 0.9 : 0.22), at: Double(i) * 0.05)
            }
            let t = Double(count) * 0.05, enabled = mode != "setup"
            let selected = try XCTUnwrap(tracker.select([ball(1000, 0.95), tracker.latest!.ball],
                at: t, size: size, allowStationaryReacquisition: enabled))
            XCTAssertEqual(selected.x * 1280, mode == "weak_static" ? 1000 : tracker.latest!.ball.x * 1280,
                           accuracy: 0.01, mode)
            XCTAssertEqual(tracker.followCrop(at: t, size: size,
                allowStationaryReacquisition: enabled) == nil, mode == "weak_static", mode)
            if mode == "weak_static" {
                // Reacquisition cannot promote a weak distant guess into a measured ball.
                XCTAssertNil(tracker.select([ball(1000, 0.12)], at: t, size: size,
                                           allowStationaryReacquisition: true))
                XCTAssertNil(tracker.select([ball(669)], at: t, size: size,
                                           allowStationaryReacquisition: true))
                XCTAssertNotNil(tracker.select([ball(669, 0.9)], at: t, size: size,
                                              allowStationaryReacquisition: true))
                // After a real shot and a detection gap, the same weak O must
                // neither capture the tracker again nor prevent room recovery.
                tracker.accept(ball(1000, 0.95), at: t)
                tracker.accept(nil, at: t + 0.3)
                XCTAssertNil(tracker.select([ball(669)], at: t + 2, size: size,
                                           allowStationaryReacquisition: true))
                XCTAssertEqual(tracker.select([ball(669), ball(1000, 0.9)], at: t + 2, size: size,
                    allowStationaryReacquisition: true)?.x, 1000.0 / 1280)
                tracker.reset()
                tracker.accept(ball(669), at: t)
                XCTAssertNotNil(tracker.followCrop(at: t + 0.02, size: size,
                                                  allowStationaryReacquisition: true))
            }
        }
    }

    func testRecordedBounceKeepsItsEvidenceWhenCadenceCrossesFifty() throws {
        struct Fixture: Decodable {
            let corners: [[Double]], reference: [Double], frames: [[Double]], contact: Double
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-cadence-transition.json")
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let c = f.corners.map { CGPoint(x: $0[0] * 1280, y: $0[1] * 720) }
        let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
        for mode in ["recorded", "faster_return", "held", "unknown", "no_return"] {
            var detector = WallImpactDetector(board: board, reference: WallBallReference(f.reference),
                imageWidth: 1280, layout: .fourColumns)
            var hits: [WallImpactDetector.Impact] = []
            for r in f.frames {
                detector.processingFPS = mode == "faster_return" && r[0] > f.contact ? 60 : r[6]
                if r[1] >= 0.08, mode != "no_return" || r[0] <= f.contact + 0.001 {
                    detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4],
                        hand: mode == "held" ? .held : mode == "unknown" ? .unknown : .clear))
                }
                hits += detector.impacts(now: r[0])
            }
            let valid = ["recorded", "faster_return"].contains(mode)
            XCTAssertEqual(hits.count, valid ? 1 : 0, mode)
            if let hit = hits.first {
                XCTAssertEqual(hit.t, f.contact, accuracy: 0.001)
                XCTAssertEqual(hit.box, 6)
            }
        }
    }

    func testWeakIsolatedShadowBoxDoesNotEraseRecordedApproach() throws {
        struct Fixture: Decodable {
            let corners: [[Double]], reference: [Double], frames: [[Double]], contact: Double, box: Int
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-shadow-approach.json")
        for f in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)) {
            let c = f.corners.map { CGPoint(x: $0[0] * 1280, y: $0[1] * 720) }
            let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
            for mode in ["recorded", "held", "unknown", "no_return"] {
                var detector = WallImpactDetector(board: board, reference: WallBallReference(f.reference),
                    imageWidth: 1280, layout: .fourColumns)
                detector.processingFPS = 37
                var hits: [WallImpactDetector.Impact] = []
                for r in f.frames {
                    if r[1] >= 0.08, mode != "no_return" || r[0] <= f.contact + 0.001 {
                        detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4],
                            hand: mode == "held" ? .held : mode == "unknown" ? .unknown : .clear,
                            confidence: r[1]))
                    }
                    hits += detector.impacts(now: r[0])
                }
                XCTAssertEqual(hits.count, mode == "recorded" ? 1 : 0, mode)
                if let hit = hits.first {
                    XCTAssertEqual(hit.t, f.contact, accuracy: 0.001)
                    XCTAssertEqual(hit.box, f.box)
                }
            }
        }
    }

    func testEmptyTileMarginIsAllowedButNeighbourAndOuterBoundaryStayNeutral() throws {
        let board = try XCTUnwrap(WallBoard(topLeft: .zero, topRight: CGPoint(x: 300, y: 0),
            bottomRight: CGPoint(x: 300, y: 200), bottomLeft: CGPoint(x: 0, y: 200)))
        let inside = CGPoint(x: 180, y: 100)
        XCTAssertEqual(WallTargetLayout.crossCircle.target(u: 1.8, v: 1), 5)
        XCTAssertFalse(board.isBorderline(inside, uncertainty: 5, layout: .crossCircle))
        XCTAssertTrue(board.isBorderline(inside, uncertainty: 10, layout: .crossCircle))
        XCTAssertTrue(board.isBorderline(CGPoint(x: 184, y: 100), uncertainty: 5, layout: .crossCircle))
        XCTAssertTrue(board.isBorderline(CGPoint(x: 1, y: 50), uncertainty: 5, layout: .sixTargets))
        XCTAssertTrue(board.isBorderline(CGPoint(x: 99, y: 50), uncertainty: 5, layout: .sixTargets))
    }

    func testFirstFastApproachUsesElapsedModelTimeWithoutAcceptingWeakJumps() throws {
        let size = CGSize(width: 1280, height: 720)
        func ball(_ x: Double, _ y: Double, _ d: Double, _ score: Double = 0.9) -> Detection {
            .init(score: score, x: x / 1280, y: y / 720, width: d / 1280, height: d / 720)
        }
        // The late right-side shot at 164.61 s: RF saw the ball, but the old
        // fixed 2-diameter gate discarded its first 142 px of measured travel.
        for x in [240.0, 640.0, 780.5] {
            var tracker = WallBallTracker()
            tracker.accept(ball(x, 46.2, 68.1), at: 1)
            let next = try XCTUnwrap(tracker.select([ball(x + 1, 188.3, 51.7)], at: 1.1334, size: size))
            XCTAssertEqual(next.y * 720, 188.3, accuracy: 0.01)
            XCTAssertNil(tracker.select([ball(x + 1, 188.3, 51.7, 0.12)], at: 1.1334, size: size))
            XCTAssertNil(tracker.select([ball(x + 1, 188.3, 51.7)], at: 1.0167, size: size))
            XCTAssertNil(tracker.select([ball(x + 1, 350, 51.7)], at: 1.19, size: size))
            XCTAssertNil(tracker.select([ball(x + 1, 188.3, 20)], at: 1.1334, size: size))
        }
    }

    func testMotionCanGuideInitialSearchButCannotMoveTheMeasuredBall() throws {
        let size = CGSize(width: 1280, height: 720)
        var tracker = WallBallTracker()
        let seed = Detection(score: 0.9, x: 0.609375, y: 0.3472222222222222,
                             width: 0.046875, height: 0.08333333333333333)
        tracker.accept(seed, at: 1)
        let crop = try XCTUnwrap(tracker.followCrop(at: 1.13, size: size,
            motionRegion: CGRect(x: 750, y: 360, width: 60, height: 60)))
        XCTAssertEqual(crop.midY, 390, accuracy: 1)
        XCTAssertEqual(tracker.latest?.ball.y, 250.0 / 720)
        XCTAssertNil(tracker.previous)
        let normal = tracker.followCrop(at: 1.13, size: size)
        XCTAssertEqual(tracker.followCrop(at: 1.13, size: size,
            motionRegion: CGRect(x: 100, y: 100, width: 60, height: 60)), normal)
    }

    func testLateFastRightFlightSurvivesSlowerCPUWithoutChangingContactRules() throws {
        // Measured RF boxes on the saved 18:41 clip around 161.44 s. The former
        // travel gate split this same path at 8.07 fps but retained it at 8.37.
        let c = [CGPoint(x: 0.3125105154, y: 0.3151074063), CGPoint(x: 0.6975182334, y: 0.3423061091),
                 CGPoint(x: 0.6980644086, y: 0.6947556414), CGPoint(x: 0.3269770973, y: 0.7082437276)]
            .map { CGPoint(x: $0.x * 1280, y: $0.y * 720) }
        let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
        let frames: [[Double]] = [
            [0, 778.410, 27.660, 65.856], [0.116667, 776.25, 156.797, 59.001],
            [0.268334, 776.884, 301.941, 46.668], [0.385001, 781.012, 375.003, 50.545],
            [0.518334, 792.080, 510.009, 61.261], [0.635001, 803.568, 645.375, 72.730],
            [0.768334, 790.558, 502.781, 86.574]]
        for rate in [6.0, 8.07, 8.37, 10.0, 13.0] {
            for hand in [WallHandState.clear, .held, .unknown] {
                for returns in [true, false] {
                    var detector = WallImpactDetector(board: board, reference: WallBallReference([44.0245 / 1280]),
                        imageWidth: 1280, layout: .crossCircle)
                    detector.usesSparseDepthConsistency = true; detector.rejectBorderline = true
                    detector.processingFPS = rate
                    var found = [WallImpactDetector.Impact]()
                    for r in frames {
                        if returns || r[0] <= 0.268334 {
                            detector.add(.init(t: r[0], x: r[1], y: r[2], d: r[3], hand: hand))
                        }
                        found += detector.impacts(now: r[0])
                    }
                    found += detector.impacts(now: 1.0)
                    XCTAssertEqual(found.count, hand == .clear && returns ? 1 : 0, "\(rate), \(hand), return \(returns)")
                    if let hit = found.first {
                        XCTAssertEqual(hit.box, 3)
                        XCTAssertEqual(hit.t, 0.268334, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testMissingQuarterSecondCannotTurnReturnIntoAdjacentCellContact() throws {
        let board = try XCTUnwrap(WallBoard(topLeft: CGPoint(x: 400, y: 227), topRight: CGPoint(x: 893, y: 246),
            bottomRight: CGPoint(x: 894, y: 500), bottomLeft: CGPoint(x: 419, y: 510)))
        // Capture times from the failed 151.70 s shot. The encoded video's
        // coarser clock rounds this 250.14 ms gap down to 250 ms; do not bridge it.
        let frames: [[Double]] = [[0, 759.12, 29.15, 64.65], [0.25014, 763.28, 290, 59.50],
            [0.38355, 754.66, 355.86, 52.73], [0.51695, 753.83, 513.43, 68.62],
            [0.65036, 741.41, 647.81, 86.88]]
        for rate in [6.0, 8.0, 10.0, 13.0] {
            var detector = WallImpactDetector(board: board, reference: WallBallReference([44.0245 / 1280]),
                imageWidth: 1280, layout: .crossCircle)
            detector.usesSparseDepthConsistency = true; detector.rejectBorderline = true
            detector.processingFPS = rate
            var found = [WallImpactDetector.Impact]()
            for r in frames {
                detector.add(.init(t: r[0], x: r[1], y: r[2], d: r[3], hand: .clear))
                found += detector.impacts(now: r[0])
            }
            found += detector.impacts(now: 1)
            XCTAssertTrue(found.isEmpty, "\(rate) fps must not guess a middle-row hit from the return")
        }
    }
    func testFollowingUsesOnlyRecentMeasurementsAndSurvivesOneMissingFrame() throws {
        var tracker = WallBallTracker()
        let size = CGSize(width: 1280, height: 720)
        XCTAssertNil(tracker.followCrop(at: 1, size: size))
        tracker.accept(.init(score: 0.9, x: 0.4, y: 0.4, width: 0.04, height: 0.07), at: 1)
        tracker.accept(.init(score: 0.9, x: 0.44, y: 0.42, width: 0.04, height: 0.07), at: 1.08)
        let crop = try XCTUnwrap(tracker.followCrop(at: 1.16, size: size))
        // Both continued flight and a reversal remain in view.
        XCTAssertTrue(crop.contains(CGPoint(x: 0.48 * 1280, y: 0.44 * 720)))
        XCTAssertTrue(crop.contains(CGPoint(x: 0.40 * 1280, y: 0.40 * 720)))
        tracker.accept(nil, at: 1.16)
        XCTAssertNotNil(tracker.followCrop(at: 1.24, size: size))
        XCTAssertEqual(tracker.latest?.t, 1.08) // no invented ball on a missed frame
        XCTAssertNil(tracker.followCrop(at: 1.30, size: size))
        XCTAssertNil(tracker.followCrop(at: 1.08, size: size))
        tracker.reset()
        XCTAssertNil(tracker.followCrop(at: 1.31, size: size))
    }

    func testFollowingCropRemainsInsideEveryImageEdge() throws {
        for size in [CGSize(width: 1280, height: 720), CGSize(width: 640, height: 480)] {
            for x in [0.0, 0.5, 1.0] { for y in [0.0, 0.5, 1.0] {
                var tracker = WallBallTracker()
                tracker.accept(.init(score: 0.9, x: x, y: y, width: 0.4, height: 0.5), at: 1)
                let crop = try XCTUnwrap(tracker.followCrop(at: 1.1, size: size))
                XCTAssertGreaterThan(crop.width, 0)
                XCTAssertEqual(crop, crop.integral)
                XCTAssertGreaterThanOrEqual(crop.minX, 0)
                XCTAssertGreaterThanOrEqual(crop.minY, 0)
                XCTAssertLessThanOrEqual(crop.maxX, size.width)
                XCTAssertLessThanOrEqual(crop.maxY, size.height)
            } }
        }
    }

    func testCentreHoldUsesFollowScaleAndKeepsCalibrationAnchorInView() throws {
        let corners = [CGPoint(x: 0.175, y: 0.287), CGPoint(x: 0.565, y: 0.368),
                       CGPoint(x: 0.554, y: 0.704), CGPoint(x: 0.175, y: 0.701)]
        let size = CGSize(width: 1280, height: 720)
        let crop = try XCTUnwrap(WallBallTracker.referenceCrop(corners: corners, size: size))
        XCTAssertEqual(crop.width, 384, accuracy: 1)
        XCTAssertEqual(crop.height, 384, accuracy: 1)
        XCTAssertTrue(crop.contains(CGPoint(x: 501, y: 375)))
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(crop))
        XCTAssertNil(WallBallTracker.referenceCrop(corners: [], size: size))
    }

    func testRecordedCPUContactsSelectReviewedSquaresOnce() throws {
        for scenario in try fixture().scenarios where scenario.expectedBox != nil {
            let hits = try replay(scenario)
            XCTAssertEqual(hits.count, 1, scenario.name)
            XCTAssertEqual(hits.first?.box, scenario.expectedBox, scenario.name)
            XCTAssertEqual(hits.first?.t ?? 0, scenario.expectedTime, accuracy: 0.09, scenario.name)
        }
    }

    func testPartialBallSizeDipCannotClaimEarlierSquare() throws {
        let scenario = try XCTUnwrap(try fixture().scenarios.first { $0.name == "early_false_minimum" })
        let hits = try replay(scenario)
        XCTAssertFalse(hits.contains { $0.t < 59.18 || $0.box == 2 })
        XCTAssertLessThanOrEqual(hits.count, 1)
    }

    func testRecordedFlightsStillRequireReleaseAndMeasuredRebound() throws {
        for scenario in try fixture().scenarios where scenario.expectedBox != nil {
            for mode in ["held", "unknown", "no_return"] {
                XCTAssertTrue(try replay(scenario, mode: mode).isEmpty, "\(scenario.name): \(mode)")
            }
        }
    }

    private struct Fixture: Decodable {
        let width, height: Double
        let corners: [[Double]]
        let reference: [Double]
        let scenarios: [Scenario]
    }
    private struct Scenario: Decodable {
        let name: String
        let expectedTime: Double
        let expectedBox: Int?
        let frames: [[Double]]
    }
    private func fixture() throws -> Fixture {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-cpu-follow-shots.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
    }
    private func replay(_ scenario: Scenario, mode: String = "original") throws -> [WallImpactDetector.Impact] {
        let f = try fixture()
        let c = f.corners.map { CGPoint(x: $0[0] * f.width, y: $0[1] * f.height) }
        let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
        var detector = WallImpactDetector(board: board, reference: WallBallReference(f.reference), imageWidth: f.width, layout: .crossCircle)
        detector.processingFPS = 13
        detector.usesSparseDepthConsistency = true
        detector.rejectBorderline = true
        var hits: [WallImpactDetector.Impact] = []
        for r in scenario.frames {
            if r[1] > 0, !(mode == "no_return" && r[0] > scenario.expectedTime + 0.001) {
                let hand: WallHandState = mode == "held" ? .held : mode == "unknown" ? .unknown : WallHandState(rawValue: Int(r[5]))!
                detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4], hand: hand))
            }
            hits += detector.impacts(now: r[0])
        }
        hits += detector.impacts(now: .infinity)
        return hits
    }

    func testSparseDepthCheckPreservesMeasuredFastReboundDuringCornerRecovery() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-isolated-corner-jumps.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let reference = WallBallReference(fixture["reference"] as! [Double])!
        for sample in fixture["cases"] as! [[String: Any]] {
            let contact = sample["candidateTime"] as! Double
            let seed = (sample["seed"] as! [[Double]]).map { CGPoint(x: $0[0], y: $0[1]) }
            let size = CGSize(width: 1280, height: 720)
            var alignment = WallBoardAlignment(corners: seed, referenceCorners: seed)
            var shots = WallAlignedShotTracker()
            var found: [WallImpactDetector.Impact] = []
            for row in sample["frames"] as! [[String: Any]] {
                let t = row["t"] as! Double
                if row["checked"] as! Bool {
                    let measured = (row["measured"] as? [[Double]])?.map { CGPoint(x: $0[0], y: $0[1]) }
                    alignment.observe(measured, at: t, size: size)
                }
                let o = (row["ball"] as? [Double]).map {
                    WallImpactDetector.Observation(t: t, x: $0[0], y: $0[1], d: $0[2],
                        hand: WallHandState(rawValue: Int($0[3])) ?? .unknown)
                }
                found += shots.process(o, at: t, update: alignment.update,
                    retainEvidence: alignment.canRetainEvidence(at: t), canScore: alignment.canScore(at: t),
                    reference: reference, size: size, fps: row["fps"] as! Double,
                    usesSparseDepthConsistency: true).filter { abs($0.t - contact) < 0.01 }
            }
            let expected = sample["shouldRecover"] as! Bool
            XCTAssertEqual(found.count, expected ? 1:0, "\(contact)")
            if expected { XCTAssertEqual(found.first?.box, sample["target"] as? Int) }
        }
    }
}
#endif
