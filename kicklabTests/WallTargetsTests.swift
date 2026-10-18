#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallTargetsTests: XCTestCase {
    private let corners = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.15),
                           CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.9)]

    private func model() -> WallTargetsModel {
        let defaults = UserDefaults(suiteName: "WallTargetsTests.\(UUID().uuidString)")!
        return WallTargetsModel(defaults: defaults)
    }

    func testScoringRequiresCalibrationAndExplicitPlay() {
        let model = model()
        XCTAssertFalse(model.startPlay())
        model.record(box: 1, u: 0.5, v: 0.5)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.setCorners(corners))
        model.record(box: 1, u: 0.5, v: 0.5)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.finishReference(Array(repeating: 0.04, count: 6)))
        XCTAssertTrue(model.startPlay())
        model.record(box: 1, u: 0.5, v: 0.5)
        XCTAssertEqual(model.boxesHit, [1])
        model.pause()
        model.record(box: 2, u: 1.5, v: 0.5)
        XCTAssertEqual(model.boxesHit, [1])
    }

    func testSavedCornersNeverAuthorizeANewCameraSession() {
        let defaults = UserDefaults(suiteName: "WallTargetsTests.\(UUID().uuidString)")!
        let first = WallTargetsModel(defaults: defaults)
        XCTAssertTrue(first.setCorners(corners))
        let reopened = WallTargetsModel(defaults: defaults)
        XCTAssertEqual(reopened.corners, corners)
        XCTAssertTrue(reopened.cornersNotSet)
        XCTAssertFalse(reopened.startPlay())
    }

    func testFailedSearchAndInterruptionCannotScore() {
        let model = model()
        model.setCorners(corners)
        model.finishReference(Array(repeating: 0.04, count: 6))
        model.startPlay()
        model.beginCalibration()
        model.record(box: 1, u: 0.5, v: 0.5)
        model.calibrationFailed()
        XCTAssertFalse(model.startPlay())
        XCTAssertTrue(model.hits.isEmpty)
        model.setCorners(corners)
        model.finishReference(Array(repeating: 0.04, count: 6))
        model.startPlay()
        model.invalidateCalibration()
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.startPlay())
    }

    func testCountdownStartsClockAndOutsideEventsDoNotRestartItOrTheNextRound() {
        let model = model()
        model.setCorners(corners)
        model.finishReference(Array(repeating: 0.04, count: 6))
        let start = Date(timeIntervalSince1970: 100)
        model.startPlay(at: start)
        model.record(box: nil, u: -0.5, v: 0.5)
        model.record(box: 1, u: 2.5, v: 1.5)
        XCTAssertEqual(model.roundStart, start)
        XCTAssertEqual(model.elapsed(at: start.addingTimeInterval(2)), 2)
        XCTAssertTrue(model.hits.isEmpty)
        for box in 1...6 {
            model.record(box: box, u: Double((box - 1) % 3) + 0.5,
                         v: Double((box - 1) / 3) + 0.5, at: start.addingTimeInterval(Double(box)))
        }
        XCTAssertEqual(model.clearTime, 6)
        model.record(box: nil, u: -1, v: 0, at: start.addingTimeInterval(20))
        XCTAssertEqual(model.boxesHit.count, 6)
        model.record(box: 1, u: 0.5, v: 0.5, at: start.addingTimeInterval(21))
        XCTAssertEqual(model.boxesHit, [1])
    }

    func testCalibrationRejectsCrossedCollapsedAndOffscreenCorners() {
        XCTAssertTrue(WallBoard.validCalibration(corners))
        XCTAssertFalse(WallBoard.validCalibration([corners[0], corners[2], corners[1], corners[3]]))
        XCTAssertFalse(WallBoard.validCalibration(Array(repeating: corners[0], count: 4)))
        XCTAssertFalse(WallBoard.validCalibration([CGPoint(x: -0.1, y: 0.2)] + Array(corners.dropFirst())))
        XCTAssertFalse(WallBoard.validCalibration(Array(corners.prefix(3))))
        XCTAssertNil(WallBoard.homography(from: [], to: []))
    }

    func testPerspectiveMappingRoundTripsAcrossBoard() throws {
        let board = try XCTUnwrap(WallBoard(topLeft: corners[0], topRight: corners[1],
                                            bottomRight: corners[2], bottomLeft: corners[3]))
        for u in stride(from: 0.0, through: 3.0, by: 0.25) {
            for v in stride(from: 0.0, through: 2.0, by: 0.25) {
                let p = board.boardPoint(board.imagePoint(u: u, v: v))
                XCTAssertEqual(p.x, u, accuracy: 1e-9)
                XCTAssertEqual(p.y, v, accuracy: 1e-9)
            }
        }
    }

    func testBlinkSearchRequiresFourDotsAndEnoughFrames() throws {
        let w = WallCornerFinder.width, h = WallCornerFinder.height
        let dark = [UInt8](repeating: 40, count: w * h)
        var lit = dark
        for (x, y) in [(64, 36), (256, 36), (256, 144), (64, 144)] {
            for dy in -3...3 { for dx in -3...3 { lit[(y + dy) * w + x + dx] = 230 } }
        }
        let frames: [WallCornerFinder.Frame] = (0..<6).map {
            .init(t: Double($0), luma: $0 < 3 ? dark : lit)
        }
        let found = try XCTUnwrap(WallCornerFinder.corners(in: frames, on: [3...5], off: [0...2]))
        XCTAssertEqual(found[0].x, 64.5 / Double(w), accuracy: 0.001)
        XCTAssertEqual(found[2].y, 144.5 / Double(h), accuracy: 0.001)
        XCTAssertNil(WallCornerFinder.corners(in: Array(frames.prefix(4)), on: [3...5], off: [0...2]))
        XCTAssertNil(WallCornerFinder.corners(in: (0..<6).map { .init(t: Double($0), luma: dark) }, on: [3...5], off: [0...2]))
    }

    private func trajectory(depthOnly: Bool, bounce: Bool = true) -> [WallImpactDetector.Impact] {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
                              bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: 50.0 / 1280, count: 6)), imageWidth: 1280)
        var impacts: [WallImpactDetector.Impact] = []
        for f in 0..<90 {
            let offset = Double(f - 35)
            let d = bounce ? 50 + abs(offset) * 2 : 50
            let x = depthOnly ? 640 : 640 - abs(offset) * 4
            detector.add(.init(t: Double(f) / 60, x: x, y: 360, d: d, hand: .clear))
            impacts += detector.impacts(now: Double(f) / 60)
        }
        impacts += detector.impacts(now: .infinity)
        return impacts
    }

    func testFrontalDepthReboundAndVisibleTurnEachCountOnce() {
        XCTAssertEqual(trajectory(depthOnly: true).count, 1)
        XCTAssertEqual(trajectory(depthOnly: false).count, 1)
    }

    func testStationaryBallDoesNotCount() {
        XCTAssertTrue(trajectory(depthOnly: true, bounce: false).isEmpty)
    }

    func testSingleFrameSizeGlitchIsNotAFrontalRebound() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
                              bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: 50.0 / 1280, count: 6)), imageWidth: 1280)
        var hits: [WallImpactDetector.Impact] = []
        for f in 0..<90 {
            detector.add(.init(t: Double(f) / 60, x: 640, y: 360, d: f == 35 ? 40 : 60, hand: .clear))
            hits += detector.impacts(now: Double(f) / 60)
        }
        XCTAssertTrue(hits.isEmpty)
        XCTAssertTrue(detector.impacts(now: .infinity).isEmpty)
    }

    func testBadObservationsCannotPoisonDepthHistory() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
                              bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: 50.0 / 1280, count: 6)), imageWidth: 1280)
        detector.add(.init(t: 1, x: 640, y: 360, d: 50))
        detector.add(.init(t: 1, x: 640, y: 360, d: 50))
        detector.add(.init(t: 0, x: 640, y: 360, d: 50))
        detector.add(.init(t: 2, x: .nan, y: 360, d: 50))
        detector.add(.init(t: 3, x: 640, y: 360, d: 0))
        XCTAssertEqual(detector.history.count, 1)
        XCTAssertTrue(detector.impacts(now: 10).isEmpty)
    }

    func testRecordedSizeSpikeCannotBecomeTheContactFrame() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-impact-size-spike.json")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [[String: Double]]
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
                              bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: 50.0 / 1280, count: 6)), imageWidth: 1280)
        detector.processingFPS = 24
        // The preceding live history established a wall-size gate near 70 px.
        for f in 0..<30 { detector.add(.init(t: 44 + Double(f) / 24, x: 600, y: 300, d: 55, hand: .clear)) }
        var found: [WallImpactDetector.Impact] = []
        for r in rows {
            let t = r["t"]!
            detector.add(.init(t: t, x: r["x"]!, y: r["y"]!, d: r["d"]!, hand: .clear))
            let impacts = detector.impacts(now: t)
            for hit in impacts { XCTAssertLessThanOrEqual(hit.d, detector.wallGate) }
            found += impacts
        }
        let remaining = detector.impacts(now: .infinity)
        for hit in remaining { XCTAssertLessThanOrEqual(hit.d, detector.wallGate) }
        found += remaining
        XCTAssertFalse(found.isEmpty, "Reject the oversized frame without losing the real rebound")
    }
    func testReferencePhaseCannotScoreAndSixValidSamplesAreRequired() {
        let m = model()
        m.setCorners(corners)
        XCTAssertFalse(m.startPlay())
        m.beginReference()
        for box in 1...6 {
            m.showReference(box: box, progress: 0.8)
            m.record(box: box, u: Double((box - 1) % 3) + 0.5, v: Double((box - 1) / 3) + 0.5)
        }
        XCTAssertTrue(m.hits.isEmpty)
        XCTAssertNil(m.roundStart)
        XCTAssertFalse(m.finishReference([0.04, 0.04]))
        XCTAssertFalse(m.startPlay())
        XCTAssertTrue(m.finishReference(Array(repeating: 0.04, count: 6)))
        XCTAssertTrue(m.startPlay())
        m.invalidateCalibration()
        XCTAssertNil(m.wallReference)
        XCTAssertFalse(m.startPlay())
    }

    func testReferenceProfileValidationAndSpatialInterpolation() throws {
        XCTAssertNil(WallBallReference([0.04]))
        XCTAssertNil(WallBallReference([.nan, 0.04, 0.04, 0.04, 0.04, 0.04]))
        XCTAssertNil(WallBallReference([0.20, 0.04, 0.04, 0.04, 0.04, 0.04]))
        let profile = try XCTUnwrap(WallBallReference([0.04, 0.05, 0.06, 0.04, 0.05, 0.06]))
        XCTAssertEqual(profile.diameter(u: 1, v: 1, imageWidth: 1000), 45, accuracy: 0.001)
        XCTAssertEqual(profile.diameter(u: 3, v: 2, imageWidth: 1000), 60, accuracy: 0.001)
    }

    func testReferenceHoldNeedsVisibleStableBallAtRequestedCentre() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 900, y: 0), bottomRight: CGPoint(x: 900, y: 600), bottomLeft: CGPoint(x: 0, y: 600))!
        var collector = WallReferenceCollector(board: board, target: 1, imageWidth: 900)
        var accepted: Double?
        for f in 0...95 {
            let t = Double(f) / 30
            let update = collector.add(.init(t: t, x: 150 + sin(t) * 2, y: 150, d: 60, score: 0.8, aspect: 1), now: t)
            if let d = update.diameter { accepted = d }
            if f < 90 { XCTAssertNil(update.diameter) }
        }
        XCTAssertEqual(accepted ?? 0, 60.0 / 900, accuracy: 0.001)
        var wrong = WallReferenceCollector(board: board, target: 1, imageWidth: 900)
        for f in 0...120 {
            let t = Double(f) / 30
            XCTAssertNil(wrong.add(.init(t: t, x: 450, y: 150, d: 60, score: 0.8, aspect: 1), now: t).diameter)
        }
        XCTAssertEqual(collector.add(nil, now: 5).progress, 0)
        XCTAssertNil(collector.add(.init(t: 5.1, x: 150, y: 150, d: 60, score: 0.8, aspect: 1), now: 5.1).diameter)
    }

    func testHandsAndMissingPoseCannotMasqueradeAsRelease() {
        let body = CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.8)
        let held = WallHandTracker.Snapshot(t: 1, wrists: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.5)], personCount: 1)
        XCTAssertEqual(held.state(ball: CGPoint(x: 0.42, y: 0.4), diameter: 0.1, aspect: 1, person: body, now: 1.05), .held)
        XCTAssertEqual(held.state(ball: CGPoint(x: 0.9, y: 0.1), diameter: 0.1, aspect: 1, person: body, now: 1.05), .clear)
        XCTAssertEqual(held.state(ball: CGPoint(x: 0.9, y: 0.1), diameter: 0.1, aspect: 1, person: body, now: 1.3), .unknown)
        let missing = WallHandTracker.Snapshot(t: 1, wrists: [], personCount: 1)
        XCTAssertEqual(missing.state(ball: CGPoint(x: 0.4, y: 0.4), diameter: 0.1, aspect: 1, person: body, now: 1.05), .unknown)
    }

    func testNoImplicitDepthCalibrationOrUnknownHandScoring() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0), bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        for reference in [nil, WallBallReference(Array(repeating: 50.0 / 1280, count: 6))] {
            var detector = WallImpactDetector(board: board, reference: reference, imageWidth: 1280)
            for f in 0..<90 {
                let offset = Double(f - 35)
                detector.add(.init(t: Double(f)/60, x: 640 - abs(offset)*4, y: 360, d: 50 + abs(offset)*2))
                XCTAssertTrue(detector.impacts(now: Double(f)/60).isEmpty)
            }
            XCTAssertTrue(detector.impacts(now: .infinity).isEmpty)
        }
    }

    func testRecordedHeldReferenceDoesNotProduceShots() throws {
        struct Fixture: Decodable { let corners: [[Double]]; let frameWidth, frameHeight, wallDiameterPixels: Double; let frames: [[String: Double]] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/wall-held-reference.json")
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let p = f.corners.map { CGPoint(x: $0[0]*f.frameWidth, y: $0[1]*f.frameHeight) }
        let board = WallBoard(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])!
        var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: f.wallDiameterPixels/f.frameWidth, count: 6)), imageWidth: f.frameWidth)
        var previous: Double?, fps = 60.0
        for r in f.frames {
            let t = r["t"]!
            if let previous { fps = 0.9*fps + 0.1/(t-previous) }
            previous = t; detector.processingFPS = fps
            if r["ball_score"]! >= 0.2 {
                detector.add(.init(t: t, x: r["bx"]!*f.frameWidth, y: r["by"]!*f.frameHeight,
                    d: (r["bw"]!*f.frameWidth+r["bh"]!*f.frameHeight)/2,
                    hand: WallHandState(rawValue: Int(r["hand_state"]!))!))
            }
            XCTAssertTrue(detector.impacts(now: t).isEmpty, "Held ball must not score at \(t)")
        }
        XCTAssertTrue(detector.impacts(now: .infinity).isEmpty)
    }

    func testRecordedReleasedShotsSurviveHandAndReferenceGates() throws {
        struct Throw: Decodable { let t: Double; let accept: [Int] }
        struct Scenario: Decodable { let name: String; let width, height, diameter: Double; let corners: [[Double]]; let frames: [[Double]]; let `throws`: [Throw] }
        struct Fixture: Decodable { let scenarios: [Scenario] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/wall-released-shots.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for f in fixture.scenarios {
            let c = f.corners.map { CGPoint(x: $0[0], y: $0[1]) }
            let board = WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3])!
            var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: f.diameter/f.width, count: 6)), imageWidth: f.width)
            var previous: Double?, fps = 60.0, hits: [WallImpactDetector.Impact] = []
            for r in f.frames {
                if let previous { fps = 0.9*fps + 0.1/(r[0]-previous) }
                previous = r[0]; detector.processingFPS = fps
                if r[1] >= 0.2 { detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4], hand: WallHandState(rawValue: Int(r[5]))!)) }
                hits += detector.impacts(now: r[0])
            }
            hits += detector.impacts(now: .infinity)
            for shot in f.throws {
                XCTAssertTrue(hits.contains { abs($0.t-shot.t) <= 0.2 && shot.accept.contains($0.box ?? 0) }, "\(f.name) lost shot at \(shot.t)")
            }
            XCTAssertEqual(hits.filter { $0.box != nil }.count, f.throws.count)
        }
    }

    func testOneBadReferenceBoxDoesNotRestartAnOtherwiseStableHold() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 900, y: 0), bottomRight: CGPoint(x: 900, y: 600), bottomLeft: CGPoint(x: 0, y: 600))!
        var collector = WallReferenceCollector(board: board, target: 1, imageWidth: 900)
        var accepted: Double?
        for f in 0...95 {
            let t = Double(f)/30
            let sample = WallReferenceCollector.Sample(t: t, x: f == 45 ? 450 : 150, y: 150, d: 60, score: 0.8, aspect: 1)
            if let d = collector.add(sample, now: t).diameter { accepted = d }
        }
        XCTAssertNotNil(accepted)
    }

    func testCropCoordinatesAndClippedDiameterAreHandledInSourceFrame() throws {
        let size = CGSize(width: 1280, height: 720)
        let crop = CGRect(x: 200, y: 80, width: 640, height: 440)
        let ball = Detection(score: 0.8, x: 0.5, y: 0.25, width: 0.1, height: 0.1)
        let mapped = try XCTUnwrap(WallBallTracker.map(ball, from: crop, size: size))
        XCTAssertEqual(mapped.x * 1280, 520, accuracy: 0.001)
        XCTAssertEqual(mapped.y * 720, 190, accuracy: 0.001)
        XCTAssertEqual(mapped.width * 1280, 64, accuracy: 0.001)
        XCTAssertEqual(mapped.height * 720, 44, accuracy: 0.001)
        XCTAssertNil(WallBallTracker.map(Detection(score: 0.9, x: 0.99, y: 0.5, width: 0.1, height: 0.1), from: crop, size: size))
        let view = try XCTUnwrap(WallBallTracker.crop(corners: corners, size: size))
        for c in corners { XCTAssertTrue(view.contains(CGPoint(x: c.x * size.width, y: c.y * size.height))) }
        XCTAssertNil(WallBallTracker.crop(corners: [], size: size))
    }

    func testWeakBallNeedsRecentMeasuredTrackAndMissingFramesAreNotInvented() throws {
        var tracker = WallBallTracker()
        let size = CGSize(width: 1000, height: 1000)
        let strong = Detection(score: 0.9, x: 0.5, y: 0.5, width: 0.05, height: 0.05)
        let weak = Detection(score: 0.12, x: 0.51, y: 0.50, width: 0.05, height: 0.05)
        XCTAssertNil(tracker.select([weak], at: 1, size: size))
        tracker.accept(try XCTUnwrap(tracker.select([strong], at: 1, size: size)), at: 1)
        XCTAssertNotNil(tracker.select([weak], at: 1.05, size: size))
        XCTAssertNil(tracker.select([], at: 1.05, size: size))
        XCTAssertNil(tracker.select([Detection(score: 0.15, x: 0.9, y: 0.8, width: 0.05, height: 0.05)], at: 1.05, size: size))
        XCTAssertNil(tracker.select([Detection(score: 0.8, x: 0.5, y: 0.5, width: 0.4, height: 0.4)], at: 1.05, size: size))
        tracker.accept(nil, at: 1.25)
        XCTAssertNil(tracker.latest)
        XCTAssertNil(tracker.select([weak], at: 1.26, size: size))
    }

    func testDepthReboundMayKeepMovingDownAndNeedsSustainedMeasuredRecovery() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0), bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        for fps in [24.0, 30.0, 60.0] {
            var detector = WallImpactDetector(board: board, reference: WallBallReference(Array(repeating: 50.0/1280, count: 6)), imageWidth: 1280)
            detector.processingFPS = fps
            var hits: [WallImpactDetector.Impact] = []
            for f in 0..<Int(fps*2) {
                let t = Double(f)/fps, offset = t-0.8
                // A downward throw can return towards the camera while still
                // travelling down the image: no large 2D direction reversal.
                let d = 50 + abs(offset)*90
                detector.add(.init(t: t, x: 640, y: 250+t*400, d: d, hand: .clear))
                hits += detector.impacts(now: t)
            }
            hits += detector.impacts(now: .infinity)
            XCTAssertEqual(hits.count, 1)
            XCTAssertEqual(hits.first?.box, 5)
            XCTAssertEqual(hits.first?.t ?? 0, 0.8, accuracy: 1/fps)
        }
    }

    func testFullFramePoseBoundsDoNotMistakeACroppedPersonForHandClearance() {
        let body = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8)
        let pose = WallHandTracker.Snapshot(t: 1, wrists: [], personCount: 1, bodies: [body])
        XCTAssertEqual(pose.state(ball: CGPoint(x: 0.3, y: 0.5), diameter: 0.06, aspect: 1, person: nil, now: 1.05), .unknown)
        XCTAssertEqual(pose.state(ball: CGPoint(x: 0.8, y: 0.5), diameter: 0.06, aspect: 1, person: nil, now: 1.05), .clear)
        XCTAssertEqual(pose.state(ball: CGPoint(x: 0.8, y: 0.5), diameter: 0.06, aspect: 1, person: nil, now: 1.3), .unknown)
    }

    func testRecordedDownwardReboundAndWrongBoxUseWallContactInsteadOfLaterTurn() throws {
        struct Scenario: Decodable { let name: String; let expectedTime: Double; let expectedBox: Int; let frames: [[Double]] }
        struct Fixture: Decodable { let width, height: Double; let corners: [[Double]]; let reference: [Double]; let scenarios: [Scenario] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/wall-contact-regressions.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        let c = fixture.corners.map { CGPoint(x: $0[0]*fixture.width, y: $0[1]*fixture.height) }
        let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
        for scenario in fixture.scenarios {
            var detector = WallImpactDetector(board: board, reference: WallBallReference(fixture.reference), imageWidth: fixture.width)
            detector.processingFPS = 29
            var hits: [WallImpactDetector.Impact] = []
            for r in scenario.frames {
                if r[1] >= 0.2 { detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4], hand: WallHandState(rawValue: Int(r[5]))!)) }
                hits += detector.impacts(now: r[0])
            }
            hits += detector.impacts(now: .infinity)
            XCTAssertEqual(hits.count, 1, scenario.name)
            XCTAssertEqual(hits.first?.box, scenario.expectedBox, scenario.name)
            XCTAssertEqual(hits.first?.t ?? 0, scenario.expectedTime, accuracy: 0.08, scenario.name)
            XCTAssertTrue(detector.takeDecisions().contains { $0.reason == "accepted" })
            XCTAssertTrue(detector.takeDecisions().isEmpty)
        }
    }

    func testReprocessedMissingDetectionsRecoverSixReviewedContactsWithoutHeldBallScores() throws {
        struct Expected: Decodable { let t: Double; let box: Int }
        struct Scenario: Decodable { let name: String; let corners: [[Double]]; let reference: [Double]; let frames: [[Double]]; let expected: [Expected] }
        struct Fixture: Decodable { let width, height: Double; let scenarios: [Scenario] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/wall-tracking-regressions.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        for scenario in fixture.scenarios {
            let c = scenario.corners.map { CGPoint(x: $0[0]*fixture.width, y: $0[1]*fixture.height) }
            let board = try XCTUnwrap(WallBoard(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3]))
            var detector = WallImpactDetector(board: board, reference: WallBallReference(scenario.reference), imageWidth: fixture.width)
            var hits: [WallImpactDetector.Impact] = [], last: Double?, fps = 60.0
            for r in scenario.frames {
                if let last { fps = 0.9*fps + 0.1/(r[0]-last) }; last = r[0]; detector.processingFPS = fps
                if r[6] > 0 { detector.add(.init(t: r[0], x: r[2], y: r[3], d: r[4], hand: WallHandState(rawValue: Int(r[5]))!)) }
                hits += detector.impacts(now: r[0])
            }
            hits += detector.impacts(now: .infinity)
            XCTAssertEqual(hits.count, scenario.expected.count, scenario.name)
            for e in scenario.expected {
                XCTAssertTrue(hits.contains { $0.box == e.box && abs($0.t-e.t) <= 0.12 }, scenario.name)
            }
        }
    }

    func testRecordedDelayedReboundKeepsEarlyBox3AndExistingBox5() throws {
        try checkDelayedReboundRecording(mode: "original")
    }

    func testDelayedReboundStillRequiresReleasedBallAndMeasuredReturn() throws {
        for mode in ["held", "unknown", "no_return"] {
            try checkDelayedReboundRecording(mode: mode)
        }
    }

    func testPendingContactWaitsForLastReboundMeasurementButExpires() {
        let board = WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
            bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720))!
        for finalTime in [1.42, 1.50] {
            var detector = WallImpactDetector(board: board,
                reference: WallBallReference(Array(repeating: 45.0 / 1280, count: 6)), imageWidth: 1280)
            detector.processingFPS = 24
            let samples: [(Double, Double)] = [(0.8, 70), (0.87, 60), (0.94, 52), (1, 45),
                (1.07, 46), (1.14, 47), (1.28, 49), (1.401, 53)]
            for (t, d) in samples {
                detector.add(.init(t: t, x: 700, y: 150, d: d, hand: .clear))
                XCTAssertTrue(detector.impacts(now: t).isEmpty)
            }
            XCTAssertTrue(detector.takeDecisions().contains { $0.reason == "rebound_pending" })
            detector.add(.init(t: finalTime, x: 700, y: 150, d: 57, hand: .clear))
            let hits = detector.impacts(now: finalTime) + detector.impacts(now: 2)
            XCTAssertEqual(hits.count, finalTime == 1.42 ? 1 : 0)
            if let hit = hits.first { XCTAssertEqual(hit.t, 1); XCTAssertEqual(hit.box, 2) }
        }
    }

    private func checkDelayedReboundRecording(mode: String) throws {
        struct Expected: Decodable { let t: Double; let box: Int }
        struct Scenario: Decodable {
            let name: String; let corners: [[Double]]; let frames: [[Double]]; let expected: [Expected]
        }
        struct Fixture: Decodable {
            let width, height: Double; let reference: [Double]; let scenarios: [Scenario]
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-delayed-rebound.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        let states: [WallBoardAlignment.Status] = [.checking, .ready, .obscured, .shifted, .referenceRequired]
        for scenario in fixture.scenarios {
            if mode != "original", scenario.name != "late_rebound_box3" { continue }
            var tracker = WallAlignedShotTracker()
            var hits: [WallImpactDetector.Impact] = []
            for r in scenario.frames {
                let hand: WallHandState = mode == "held" ? .held : mode == "unknown" ? .unknown : WallHandState(rawValue: Int(r[6]))!
                let measured = r[7] > 0 && !(mode == "no_return" && r[0] > 165.9)
                let observation = measured ? WallImpactDetector.Observation(t: r[0], x: r[3], y: r[4], d: r[5], hand: hand) : nil
                let update = WallBoardAlignment.Update(status: states[Int(r[8])],
                    corners: scenario.corners.map { CGPoint(x: $0[0], y: $0[1]) },
                    revision: Int(r[9]), evidenceEpoch: Int(r[10]))
                hits += tracker.process(observation, at: r[0], update: update,
                    retainEvidence: r[11] == 1, canScore: r[12] == 1,
                    reference: WallBallReference(fixture.reference),
                    size: CGSize(width: fixture.width, height: fixture.height), fps: r[1])
            }
            let expected = mode == "original" ? scenario.expected : []
            XCTAssertEqual(hits.count, expected.count, "\(scenario.name): \(mode)")
            for e in expected {
                XCTAssertTrue(hits.contains { $0.box == e.box && abs($0.t - e.t) < 0.001 }, scenario.name)
            }
        }
    }

}
#endif
