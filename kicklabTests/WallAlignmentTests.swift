#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallAlignmentTests: XCTestCase {
    private let size = CGSize(width: 1280, height: 720)
    private let corners = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.7, y: 0.2),
                           CGPoint(x: 0.7, y: 0.65), CGPoint(x: 0.2, y: 0.65)]

    private func shifted(_ points: [CGPoint], dx: Double, dy: Double) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + dx / size.width, y: $0.y + dy / size.height) }
    }

    func testReadyRequiresThreeStableChecksAndFreshEvidence() {
        var a = WallBoardAlignment(corners: corners)
        a.observe(corners, at: 0, size: size)
        a.observe(corners, at: 0.15, size: size)
        XCTAssertFalse(a.canScore(at: 0.15))
        a.observe(corners, at: 0.30, size: size)
        XCTAssertTrue(a.canScore(at: 0.30))
        XCTAssertFalse(a.canScore(at: 0.61))
        // A processing gap must not silently resume using old permission.
        a.observe(corners, at: 0.8, size: size)
        XCTAssertFalse(a.canScore(at: 0.8))
    }

    func testDriftPausesImmediatelyAndRecoversOnlyAfterStableMeasurements() {
        var a = WallBoardAlignment(corners: corners, referenceCorners: corners)
        for t in [0.0, 0.15, 0.30] { a.observe(corners, at: t, size: size) }
        let revision = a.update.revision
        let moved = shifted(corners, dx: 12, dy: -34)
        a.observe(moved, at: 0.45, size: size)
        XCTAssertEqual(a.update.status, .shifted)
        XCTAssertFalse(a.canScore(at: 0.45))
        XCTAssertGreaterThan(a.update.revision, revision) // camera discards pending contacts
        XCTAssertEqual(a.update.corners, corners)
        a.observe(moved, at: 0.6, size: size)
        XCTAssertFalse(a.canScore(at: 0.6))
        a.observe(moved, at: 0.75, size: size)
        XCTAssertTrue(a.canScore(at: 0.75))
        XCTAssertEqual(a.update.corners, moved)
    }

    func testOcclusionNeverUsesPredictedCornersAndBreaksRecoverySequence() {
        var a = WallBoardAlignment(corners: corners)
        for t in [0.0, 0.15, 0.30] { a.observe(corners, at: t, size: size) }
        a.observe(nil, at: 0.45, size: size)
        XCTAssertEqual(a.update.status, .obscured)
        XCTAssertFalse(a.canScore(at: 0.45))
        a.observe(corners, at: 0.60, size: size)
        a.observe(corners, at: 0.75, size: size)
        a.observe(nil, at: 0.90, size: size)
        a.observe(corners, at: 1.05, size: size)
        XCTAssertFalse(a.canScore(at: 1.05))
        a.observe(corners, at: 1.20, size: size)
        a.observe(corners, at: 1.35, size: size)
        XCTAssertTrue(a.canScore(at: 1.35))
    }

    func testScaleChangeRequiresNewReferenceAndCannotAutomaticallyResume() {
        var a = WallBoardAlignment(corners: corners, referenceCorners: corners)
        let scaled = corners.map { CGPoint(x: 0.45 + ($0.x - 0.45) * 1.1, y: 0.4 + ($0.y - 0.4) * 1.1) }
        a.observe(scaled, at: 0, size: size)
        XCTAssertNotEqual(a.update.status, .referenceRequired)
        a.observe(scaled, at: 0.15, size: size)
        a.observe(scaled, at: 0.3, size: size)
        XCTAssertEqual(a.update.status, .referenceRequired)
        for t in [0.45, 0.6, 0.75] { a.observe(corners, at: t, size: size) }
        XCTAssertFalse(a.canScore(at: 0.75))
    }

    func testNeutralBorderRuleUsesMeasurementErrorNotWholeBallOverlap() throws {
        let b = try XCTUnwrap(WallBoard(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 700, y: 100),
            bottomRight: CGPoint(x: 700, y: 500), bottomLeft: CGPoint(x: 100, y: 500)))
        XCTAssertTrue(b.isBorderline(CGPoint(x: 610, y: 297), uncertainty: 9))
        XCTAssertTrue(b.isBorderline(CGPoint(x: 610, y: 303), uncertainty: 9))
        XCTAssertTrue(b.isBorderline(CGPoint(x: 610, y: 504), uncertainty: 9))
        XCTAssertFalse(b.isBorderline(CGPoint(x: 610, y: 316), uncertainty: 9))
        XCTAssertFalse(b.isBorderline(CGPoint(x: 610, y: 550), uncertainty: 9))
        let p = b.boardPoint(CGPoint(x: 610, y: 316))
        XCTAssertEqual(WallBoard.box(u: p.x, v: p.y), 6)
    }

    func testLatestDisputedContactBecomesSixWithVisibleGeometry() throws {
        let b = try XCTUnwrap(WallBoard(topLeft: CGPoint(x: 228, y: 0), topRight: CGPoint(x: 751, y: 67),
            bottomRight: CGPoint(x: 722, y: 289), bottomLeft: CGPoint(x: 246, y: 258)))
        let contact = CGPoint(x: 626.88916015625, y: 189.2763671875)
        let p = b.boardPoint(contact)
        XCTAssertEqual(WallBoard.box(u: p.x, v: p.y), 6)
        XCTAssertFalse(b.isBorderline(contact, uncertainty: 3 + 42.142 * 0.15))
    }

    func testBorderlineBounceProducesOneNeutralContact() throws {
        let b = try XCTUnwrap(WallBoard(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 700, y: 100),
            bottomRight: CGPoint(x: 700, y: 500), bottomLeft: CGPoint(x: 100, y: 500)))
        var detector = WallImpactDetector(board: b, reference: WallBallReference(Array(repeating: 44.0 / 1280, count: 6)), imageWidth: 1280)
        detector.rejectBorderline = true
        var hits: [WallImpactDetector.Impact] = []
        for f in 0..<90 {
            let t = Double(f) / 60
            detector.add(.init(t: t, x: 610, y: 300, d: 44 + abs(Double(f - 35)) * 2, hand: .clear))
            hits += detector.impacts(now: t)
        }
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits.first?.box)
        XCTAssertEqual(hits.first?.borderline, true)
        XCTAssertEqual(detector.takeDecisions().filter { $0.reason == "borderline" }.count, 1)
    }

    func testModelRejectsHitsDuringDriftPreservesRoundAndInvalidatesScaledReference() {
        let m = WallTargetsModel(defaults: UserDefaults(suiteName: "WallAlignmentTests.\(UUID())")!)
        let start = Date(timeIntervalSince1970: 100)
        m.setCorners(corners); m.validateMappingForTest(); m.finishReference(Array(repeating: 0.04, count: 6)); m.startPlay(at: start)
        m.record(box: 1, u: 0.5, v: 0.5, at: start)
        m.applyAlignment(.init(status: .shifted, corners: corners, revision: 1), at: start.addingTimeInterval(1))
        m.record(box: 3, u: 2.5, v: 0.5)
        XCTAssertEqual(m.boxesHit, [1])
        XCTAssertEqual(m.elapsed(at: start.addingTimeInterval(2)), 1)
        let moved = shifted(corners, dx: 10, dy: 12)
        m.applyAlignment(.init(status: .ready, corners: moved, revision: 2), at: start.addingTimeInterval(3))
        XCTAssertEqual(m.corners, moved)
        XCTAssertEqual(m.roundStart, start.addingTimeInterval(2))
        XCTAssertNotNil(m.wallReference)
        m.recordBorderline()
        XCTAssertNotNil(m.borderlineNotice)
        XCTAssertEqual(m.boxesHit, [1])
        m.applyAlignment(.init(status: .referenceRequired, corners: moved, revision: 3))
        XCTAssertNil(m.wallReference)
        XCTAssertFalse(m.startPlay())
        XCTAssertTrue(m.referenceFailed)
    }

    func testActualRecordedCornerPatchesAndClippedCorner() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/wall-corner-frames.json")
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for c in cases {
            let width = c["width"] as! Int, height = c["height"] as! Int
            var pixels = [UInt8](repeating: 128, count: width * height)
            for patch in c["patches"] as! [[String: Any]] {
                let x = patch["x"] as! Int, y = patch["y"] as! Int, w = patch["width"] as! Int, h = patch["height"] as! Int
                let data = [UInt8](Data(base64Encoded: patch["luma"] as! String)!)
                for j in 0..<h { pixels.replaceSubrange((y + j) * width + x..<(y + j) * width + x + w, with: data[j * w..<(j + 1) * w]) }
            }
            let seed = (c["seed"] as! [[Double]]).map { CGPoint(x: $0[0], y: $0[1]) }
            let result = WallCornerTracker.corners(in: .init(width: width, height: height, luma: pixels), near: seed)
            let rowBytes = width * 4 + 16
            var bgra = [UInt8](repeating: 0, count: rowBytes * height)
            for y in 0..<height { for x in 0..<width {
                let value = pixels[y * width + x], i = y * rowBytes + x * 4
                bgra[i] = value; bgra[i + 1] = value; bgra[i + 2] = value
            } }
            let cropped = bgra.withUnsafeBufferPointer {
                WallCornerTracker.Image(bgra: $0.baseAddress!, width: width, height: height, rowBytes: rowBytes, near: seed)
            }
            XCTAssertEqual(WallCornerTracker.corners(in: cropped, near: seed), result,
                           "ROI conversion must preserve the actual marker result: \(c["name"]!)")
            if let expected = c["expected"] as? [[Double]] {
                let found = try XCTUnwrap(result, c["name"] as! String)
                let points = expected.map { CGPoint(x: $0[0], y: $0[1]) }
                XCTAssertLessThanOrEqual(WallBoardAlignment.displacement(found, points, size: size), 4, c["name"] as! String)
            } else { XCTAssertNil(result, c["name"] as! String) }
        }
    }

    func testMarkersWithBrightDistractorsAndOneOcclusion() {
        let w = 1280, h = 720
        var pixels = [UInt8](repeating: 155, count: w * h)
        // A bright line and isolated highlight may outrank an individual dot,
        // but cannot form a coherent four-corner match.
        for y in 155..<175 { for x in 930..<960 { pixels[y * w + x] = 250 } }
        for y in 200..<260 { for x in 220..<223 { pixels[y * w + x] = 240 } }
        let shifted = shifted(corners, dx: 10, dy: -24)
        for p in shifted {
            let cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
            for y in (cy - 13)...(cy + 13) { for x in (cx - 13)...(cx + 13) {
                let distance = hypot(Double(x - cx), Double(y - cy))
                pixels[y * w + x] = distance <= 7 ? 210 : 155
            } }
        }
        let found = WallCornerTracker.corners(in: .init(width: w, height: h, luma: pixels), near: corners)
        XCTAssertNotNil(found)
        if let found { XCTAssertLessThanOrEqual(WallBoardAlignment.displacement(found, shifted, size: size), 3) }
        let p = shifted[0], cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
        for y in (cy - 15)...(cy + 15) { for x in (cx - 15)...(cx + 15) { pixels[y * w + x] = 155 } }
        XCTAssertNil(WallCornerTracker.corners(in: .init(width: w, height: h, luma: pixels), near: corners))
    }

    func testRecordedStationaryCornersAllowCountdownAndTimerToAdvance() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wall-countdown-corners.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let width = fixture["width"] as! Int, height = fixture["height"] as! Int
        let seed = (fixture["seed"] as! [[Double]]).map { CGPoint(x: $0[0], y: $0[1]) }
        var alignment = WallBoardAlignment(corners: seed, referenceCorners: seed)
        let model = WallTargetsModel(defaults: UserDefaults(suiteName: "WallCountdown.\(UUID())")!)
        model.setCorners(seed); model.validateMappingForTest()
        XCTAssertTrue(model.finishReference(Array(repeating: 0.04, count: 6)))
        var readySince: Double?
        var lastTime = 0.0
        for (index, frame) in (fixture["frames"] as! [[String: Any]]).enumerated() {
            let t = frame["t"] as! Double
            var pixels = [UInt8](repeating: 128, count: width * height)
            for patch in frame["patches"] as! [[String: Any]] {
                let x = patch["x"] as! Int, y = patch["y"] as! Int
                let w = patch["width"] as! Int, h = patch["height"] as! Int
                let data = [UInt8](Data(base64Encoded: patch["luma"] as! String)!)
                for row in 0..<h {
                    pixels.replaceSubrange((y + row) * width + x..<(y + row) * width + x + w,
                                           with: data[row * w..<(row + 1) * w])
                }
            }
            let measured = WallCornerTracker.corners(in: .init(width: width, height: height, luma: pixels),
                                                     near: alignment.searchCorners)
            alignment.observe(measured, at: t, size: size)
            model.applyAlignment(alignment.update, at: Date(timeIntervalSince1970: t))
            if index >= 2 {
                XCTAssertTrue(alignment.canScore(at: t), "Stationary visible board at \(t) must not reset countdown")
            }
            if alignment.canScore(at: t) {
                if readySince == nil { readySince = t }
                if !model.isPlaying, t - readySince! >= 3 {
                    XCTAssertTrue(model.startPlay(at: Date(timeIntervalSince1970: t)))
                }
            } else { readySince = nil }
            lastTime = t
        }
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.timerStatus, "LIVE")
        XCTAssertGreaterThan(model.elapsed(at: Date(timeIntervalSince1970: lastTime)), 0.5)
        XCTAssertTrue(model.hits.isEmpty)
    }
}
#endif
