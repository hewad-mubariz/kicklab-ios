#if DEBUG
import XCTest
@testable import kicklab

@MainActor
final class WallBrickBlastTests: XCTestCase {
    private let corners = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                           CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)]
    private let start = Date(timeIntervalSince1970: 100)
    private func makeModel() -> WallTargetsModel {
        let model = WallTargetsModel(defaults: UserDefaults(suiteName: "BrickBlastTests.\(UUID())")!)
        model.showGameIntro(); XCTAssertTrue(model.selectGame(.brickBlast))
        return model
    }
    private func prepare(_ model: WallTargetsModel) {
        XCTAssertTrue(model.beginGameSetup()); XCTAssertTrue(model.setCorners(corners))
        model.validateMappingForTest(); XCTAssertTrue(model.finishReference([0.04]))
        XCTAssertTrue(model.startPlay(at: start))
    }
    private func impact(_ box: Int, t: Double) -> WallImpactDetector.Impact {
        let frame = WallGame.brickBlast.layout.target(box)!.frame
        return .init(t: t, x: 500, y: 250, d: 44, turn: 90,
                     u: frame.midX, v: frame.midY, box: box, footprint: .preview)
    }
    @discardableResult private func hit(_ model: WallTargetsModel, _ box: Int, t: Double) -> Bool {
        model.accept(impact(box, t: t), at: start.addingTimeInterval(t)) { _ in }
    }
    private func clear(_ model: WallTargetsModel) {
        for (i, box) in model.game.targetIDs.enumerated() where model.remainingHealth(for: box) > 0 {
            XCTAssertTrue(hit(model, box, t: Double(i + 1) * 2))
        }
    }

    func testDirectContactBreaksCoreAndCracksNeighbours() throws {
        let model = makeModel(); prepare(model)
        XCTAssertTrue(hit(model, 1, t: 1))
        XCTAssertEqual(model.remainingHealth(for: 1), 0)
        XCTAssertEqual(model.remainingHealth(for: 2), 1)
        XCTAssertEqual(model.hits.count, 1)
        XCTAssertEqual(model.brickScore, model.clearedBoxes.count * 100)
        XCTAssertTrue(try XCTUnwrap(model.lastHit).brickDamage.contains { !$0.shattered })
    }

    func testJointContactWithNoTargetIDShattersBothSidesAndPlaysOnce() throws {
        let model = makeModel(); prepare(model)
        let left = model.game.layout.target(1)!.frame, right = model.game.layout.target(2)!.frame
        var contact = impact(1, t: 1)
        contact.box = nil; contact.u = (left.maxX + right.minX) / 2
        XCTAssertNil(model.game.layout.target(u: contact.u, v: contact.v))
        var cues = 0
        XCTAssertTrue(model.accept(contact, at: start.addingTimeInterval(1)) { _ in cues += 1 })
        XCTAssertEqual(cues, 1); XCTAssertEqual(model.hits.count, 1)
        XCTAssertEqual(model.remainingHealth(for: 1), 0)
        XCTAssertEqual(model.remainingHealth(for: 2), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.lastHit).brickDamage.filter(\.shattered).count, 2)
    }

    func testDuplicateAndOldContactCannotDamageNeighboursAgain() {
        let model = makeModel(); prepare(model)
        XCTAssertTrue(hit(model, 1, t: 2))
        let remaining = model.damageRemaining
        XCTAssertFalse(hit(model, 1, t: 2)); XCTAssertFalse(hit(model, 2, t: 1))
        XCTAssertEqual(model.damageRemaining, remaining)
        XCTAssertTrue(hit(model, 2, t: 3))
    }

    func testVisualMotionDoesNotChangeDestructionRadius() {
        let slow = makeModel(), fast = makeModel(); prepare(slow); prepare(fast)
        var a = impact(12, t: 1), b = a; a.approachSpeed = 3; b.approachSpeed = 30
        XCTAssertTrue(slow.accept(a, at: start) { _ in }); XCTAssertTrue(fast.accept(b, at: start) { _ in })
        XCTAssertEqual(slow.lastHit?.brickDamage, fast.lastHit?.brickDamage)
    }

    func testMissingFootprintOutsidePausedAndUncertainContactsDoNotDamageWall() {
        let model = makeModel(); prepare(model)
        var missing = impact(1, t: 1); missing.footprint = nil
        var outside = impact(1, t: 2); outside.u = -0.01
        var uncertain = impact(1, t: 3); uncertain.borderline = true
        var invalid = impact(1, t: 4)
        invalid.footprint = .init(xAxis: CGPoint(x: CGFloat.nan, y: 0), yAxis: CGPoint(x: 0, y: 0.2))
        for contact in [missing, outside, uncertain, invalid] {
            XCTAssertFalse(model.accept(contact) { _ in XCTFail("No sound without valid contact") })
        }
        model.applyAlignment(.init(status: .obscured, corners: corners, revision: 2), at: start)
        XCTAssertFalse(hit(model, 1, t: 5))
        XCTAssertEqual(model.damageRemaining, 60); XCTAssertTrue(model.hits.isEmpty)
    }

    func testEmptyWallAreaDoesNotScore() {
        let model = makeModel(); prepare(model)
        var contact = impact(1, t: 1); contact.box = nil; contact.u = 0.1; contact.v = 1.9
        XCTAssertFalse(model.accept(contact) { _ in XCTFail("Empty area") })
        XCTAssertTrue(model.hits.isEmpty)
    }

    func testFullWallCompletesAndKeepsTimeAndScore() {
        let model = makeModel(); prepare(model); clear(model)
        XCTAssertEqual(model.clearedBoxes.count, 30); XCTAssertEqual(model.brickScore, 3000)
        XCTAssertEqual(model.damageRemaining, 0); XCTAssertEqual(model.gameScreen, .results)
        XCTAssertTrue(model.sessionEnded); XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.bestClearTime, model.lastHit!.at.timeIntervalSince(start))
        XCTAssertLessThan(model.hits.count, 30)
        XCTAssertFalse(hit(model, 1, t: 100))
    }

    func testCannotSwitchGameDuringSetupPlayOrSaving() {
        let model = makeModel(); XCTAssertTrue(model.beginGameSetup())
        XCTAssertFalse(model.selectGame(.clearTheWall))
        model.setCorners(corners); model.validateMappingForTest(); model.finishReference([0.04]); model.startPlay(at: start)
        XCTAssertFalse(model.selectGame(.clearTheWall)); model.finishSession()
        for state: WallRecordingState in [.recording, .saving] {
            model.recordingState = state; XCTAssertFalse(model.selectGame(.clearTheWall))
        }
        model.recordingState = .saved; XCTAssertTrue(model.selectGame(.clearTheWall))
        XCTAssertNil(model.wallReference); XCTAssertEqual(model.calibration, .required)
    }

    func testBestTimesKeepLegacyRecordsSeparate() {
        let suite = "BrickBlastTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(12, forKey: WallGame.clearTheWall.bestTimeKey)
        defaults.set(9, forKey: "wallTargets.brickBlast.stepped12.bestActiveSeconds.v3")
        defaults.set(15, forKey: "wallTargets.brickBlast.blast25.bestActiveSeconds.v4")
        let model = WallTargetsModel(defaults: defaults)
        model.showGameIntro(); model.selectGame(.brickBlast); XCTAssertNil(model.bestClearTime)
        prepare(model); clear(model)
        let result = model.bestClearTime
        XCTAssertEqual(WallTargetsModel(defaults: defaults).bestClearTime, result)
        XCTAssertTrue(model.selectGame(.clearTheWall)); XCTAssertEqual(model.bestClearTime, 12)
        XCTAssertTrue(model.selectGame(.brickBlast)); XCTAssertEqual(model.bestClearTime, result)
        XCTAssertEqual(defaults.double(forKey: "wallTargets.brickBlast.stepped12.bestActiveSeconds.v3"), 9)
        XCTAssertEqual(defaults.double(forKey: "wallTargets.brickBlast.blast25.bestActiveSeconds.v4"), 15)
    }

    func testRetryRestoresWallAndRequiresFreshMapping() {
        let model = makeModel(); prepare(model); hit(model, 12, t: 1); model.finishSession()
        XCTAssertTrue(model.beginGameSetup()); XCTAssertEqual(model.damageRemaining, 60)
        XCTAssertTrue(model.hits.isEmpty); XCTAssertNil(model.wallReference); XCTAssertNil(model.mappingReport)
        XCTAssertFalse(model.startPlay())
    }

    func testMetadataDescribesAreaRulesAndEveryDamagedBrick() throws {
        let model = makeModel(); prepare(model); hit(model, 12, t: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: model.gameMetadata)) as? [String: Any])
        XCTAssertEqual(json["layout"] as? String, "blast-wall-30-v5")
        XCTAssertEqual(json["continuousSurface"] as? Bool, true)
        XCTAssertEqual(json["targetCount"] as? Int, 30)
        XCTAssertEqual(json["ballReferenceMode"] as? String, "single-centre-hold-v1")
        let damage = try XCTUnwrap(model.lastHit).brickDamage
        XCTAssertGreaterThan(damage.count, 1)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: damage.map(\.json)))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: model.lastHit!.footprint!.json))
    }

    func testProjectedFacesMatchScoringUnderPerspectiveAndDoNotOverlap() throws {
        let board = try XCTUnwrap(WallBoard(topLeft: CGPoint(x: 180, y: 60), topRight: CGPoint(x: 1100, y: 130),
                                            bottomRight: CGPoint(x: 1060, y: 620), bottomLeft: CGPoint(x: 220, y: 690)))
        let layout = WallGame.brickBlast.layout
        for target in layout.targets {
            let r = target.hitFrame
            for fx in [0.1, 0.5, 0.9] { for fy in [0.1, 0.5, 0.9] {
                let mapped = board.boardPoint(board.imagePoint(u: r.minX + r.width * fx, v: r.minY + r.height * fy))
                XCTAssertEqual(layout.target(u: mapped.x, v: mapped.y), target.id)
            }}
            for other in layout.targets where other.id != target.id { XCTAssertFalse(r.intersects(other.hitFrame)) }
        }
    }

    func testMeasuredContactAtJointSurvivesDetectorAndDamagesBothSides() throws {
        let board = try XCTUnwrap(WallBoard(topLeft: .zero, topRight: CGPoint(x: 1280, y: 0),
                                            bottomRight: CGPoint(x: 1280, y: 720), bottomLeft: CGPoint(x: 0, y: 720)))
        let layout = WallGame.brickBlast.layout, left = layout.target(1)!.frame, right = layout.target(2)!.frame
        let centre = board.imagePoint(u: (left.maxX + right.minX) / 2, v: left.midY)
        var detector = WallImpactDetector(board: board, reference: WallBallReference([50.0 / 1280]), imageWidth: 1280, layout: layout)
        detector.rejectBorderline = true
        var hits: [WallImpactDetector.Impact] = []
        for f in 0..<90 {
            let offset = Double(f - 35), t = Double(f) / 60
            detector.add(.init(t: t, x: centre.x - abs(offset) * 4, y: centre.y, d: 50 + abs(offset) * 2, hand: .clear))
            hits += detector.impacts(now: t)
        }
        XCTAssertEqual(hits.count, 1)
        let contact = try XCTUnwrap(hits.first)
        XCTAssertNil(contact.box); XCTAssertFalse(contact.borderline); XCTAssertNotNil(contact.footprint)
        let model = makeModel(); prepare(model)
        XCTAssertTrue(model.accept(contact, at: start) { _ in })
        XCTAssertEqual(model.remainingHealth(for: 1), 0); XCTAssertEqual(model.remainingHealth(for: 2), 0)
    }
}
#endif
