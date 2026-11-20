#if DEBUG
import XCTest
@testable import kicklab

final class WallPartyRulesTests: XCTestCase {
    private let ball = WallContactFootprint(xAxis: CGPoint(x: 0.04, y: 0), yAxis: CGPoint(x: 0, y: 0.04))
    private func cell(_ id: Int) -> CGPoint {
        let r = WallTargetLayout.crossCircle.target(id)!.frame
        return CGPoint(x: r.midX, y: r.midY)
    }
    private func play(_ cells: [Int]) -> WallCrossCircle {
        var state = WallCrossCircle()
        for id in cells {
            let time = state.readyAt + 1
            XCTAssertEqual(state.hit(point: cell(id), contact: time, now: time + 0.2), id)
        }
        return state
    }
    func testAllEightWinningLinesAndSecondPlayerWin() {
        for line in WallCrossCircle.lines {
            let other = (1...9).filter { !line.contains($0) }
            let state = play([line[0], other[0], line[1], other[1], line[2]])
            XCTAssertTrue(state.finished); XCTAssertEqual(state.winner, .one)
            XCTAssertEqual(state.winningLine, line)
        }
        XCTAssertEqual(play([1, 4, 2, 5, 9, 6]).winner, .two)
    }
    func testFullBoardDrawAndNoMovesAfterMatch() {
        var state = play([1, 2, 3, 5, 4, 6, 8, 7, 9])
        XCTAssertTrue(state.finished); XCTAssertNil(state.winner)
        XCTAssertTrue(state.winningLine.isEmpty)
        let previous = state
        XCTAssertNil(state.hit(point: cell(1), contact: 100, now: 100))
        XCTAssertEqual(state, previous)
    }
    func testOccupiedCellDoesNotChangePlayerOrOverwriteOwner() {
        var state = play([5])
        let ready = state.readyAt
        XCTAssertNil(state.hit(point: cell(5), contact: ready + 1, now: ready + 1.2))
        XCTAssertEqual(state.player, .two); XCTAssertEqual(state.cells[5], .one)
        XCTAssertEqual(state.readyAt, ready)
        XCTAssertEqual(state.events.last?.kind, "occupied_cell")
        XCTAssertEqual(state.hit(point: cell(4), contact: ready + 2, now: ready + 2.2), 4)
    }
    func testHandoverRejectsReboundAndLatePriorTurnContact() {
        var state = play([5])
        let ready = state.readyAt
        XCTAssertNil(state.hit(point: cell(6), contact: ready - 0.1, now: ready + 0.3))
        XCTAssertNil(state.hit(point: cell(6), contact: 1, now: ready + 0.3))
        XCTAssertEqual(state.player, .two); XCTAssertEqual(state.cells.count, 1)
        XCTAssertEqual(state.hit(point: cell(6), contact: ready, now: ready + 0.3), 6)
    }
    func testGridGapsAndInvalidContactsDoNotClaimCells() {
        var state = WallCrossCircle()
        XCTAssertNil(state.hit(point: CGPoint(x: 1.15, y: 0.4), contact: 1, now: 1.2))
        XCTAssertNil(state.hit(point: CGPoint(x: .nan, y: 0.4), contact: 1, now: 1.2))
        XCTAssertNil(state.hit(point: cell(1), contact: 2, now: 1))
        XCTAssertNil(state.hit(point: cell(1), contact: 1, now: .nan))
        XCTAssertTrue(state.cells.isEmpty)
        for target in WallTargetLayout.crossCircle.targets {
            XCTAssertEqual(WallTargetLayout.crossCircle.target(u: target.frame.midX, v: target.frame.midY), target.id)
        }
    }
    func testKeeperUsesContactTimeAndStoresItsCollisionPose() throws {
        var state = WallGoalDuel()
        let point = CGPoint(x: 1.5, y: 0.70)
        XCTAssertFalse(state.keeper(at: 1.5).contains { WallGoalDuel.overlaps($0.frame, point: point, footprint: ball) })
        let shot = try XCTUnwrap(state.hit(point: point, footprint: ball, contact: 0, now: 1.5))
        XCTAssertEqual(shot.outcome, .saved)
        XCTAssertTrue(shot.keeper.contains { WallGoalDuel.overlaps($0.frame, point: point, footprint: ball) })
        XCTAssertEqual(shot.player, .one); XCTAssertEqual(state.player, .two)
    }
    func testGoalOpeningRequiresWholeBallInsideAndOutsideBoardIsIgnored() {
        var state = WallGoalDuel()
        XCTAssertNil(state.hit(point: CGPoint(x: -0.1, y: 0.4), footprint: ball, contact: 1, now: 1.2))
        XCTAssertEqual(state.hit(point: CGPoint(x: 0.22, y: 0.4), footprint: ball, contact: 2, now: 2.2)?.outcome, .wide)
        let next = state.readyAt
        XCTAssertEqual(state.hit(point: CGPoint(x: 0.4, y: 0.4), footprint: ball, contact: next, now: next + 0.2)?.outcome, .goal)
    }
    func testEllipseRobotOverlapDoesNotUseBoundingBoxCorners() {
        let rect = CGRect(x: 1, y: 1, width: 0.2, height: 0.2)
        let large = WallContactFootprint(xAxis: CGPoint(x: 0.1, y: 0), yAxis: CGPoint(x: 0, y: 0.1))
        XCTAssertFalse(WallGoalDuel.overlaps(rect, point: CGPoint(x: 0.92, y: 0.92), footprint: large))
        XCTAssertTrue(WallGoalDuel.overlaps(rect, point: CGPoint(x: 0.94, y: 0.94), footprint: large))
        XCTAssertTrue(WallGoalDuel.overlaps(rect, point: CGPoint(x: 0.91, y: 1.1), footprint: large))
        let rotated = WallContactFootprint(xAxis: CGPoint(x: 0.08, y: 0.08), yAxis: CGPoint(x: -0.02, y: 0.02))
        XCTAssertTrue(WallGoalDuel.overlaps(rect, point: CGPoint(x: 0.95, y: 0.95), footprint: rotated))
    }
    func testGoalHandoverAndDuplicateCannotConsumeNextPlayersShot() {
        var state = WallGoalDuel()
        let point = CGPoint(x: 0.4, y: 0.4)
        XCTAssertNotNil(state.hit(point: point, footprint: ball, contact: 1, now: 1.2))
        XCTAssertNil(state.hit(point: point, footprint: ball, contact: 1, now: 1.3))
        XCTAssertNil(state.hit(point: point, footprint: ball, contact: state.readyAt - 0.1, now: state.readyAt + 0.2))
        XCTAssertEqual(state.shots.count, 1)
        XCTAssertEqual(state.goals(.one), 1); XCTAssertEqual(state.goals(.two), 0)
    }
    func testFiveEachCanEndInDrawAndFinishedMatchIsImmutable() {
        var state = WallGoalDuel()
        for i in 0..<10 {
            let t = state.readyAt + 0.3
            let shot = state.hit(point: CGPoint(x: 0.4, y: 0.4), footprint: ball, contact: t, now: t + 0.2)
            XCTAssertEqual(shot?.outcome, .goal); XCTAssertEqual(shot?.player, i.isMultiple(of: 2) ? .one : .two)
        }
        XCTAssertTrue(state.finished); XCTAssertNil(state.winner)
        XCTAssertEqual(state.goals(.one), 5); XCTAssertEqual(state.goals(.two), 5)
        let finished = state
        state.advance(at: 1000)
        XCTAssertNil(state.hit(point: CGPoint(x: 0.4, y: 0.4), footprint: ball, contact: 1001, now: 1001.2))
        XCTAssertEqual(state, finished)
    }
    func testFiveEachHasCorrectWinnerAndSameKeeperPathForBothPlayers() throws {
        var state = WallGoalDuel()
        let firstPose = state.keeper(at: 1)
        for i in 0..<10 {
            let t = state.readyAt + 1
            XCTAssertEqual(state.keeper(at: t), firstPose)
            let head = state.keeper(at: t)[0].frame
            let p = i.isMultiple(of: 2) ? CGPoint(x: 0.4, y: 0.4) : CGPoint(x: head.midX, y: head.midY)
            let shot = try XCTUnwrap(state.hit(point: p, footprint: ball, contact: t, now: t + 0.2))
            XCTAssertEqual(shot.outcome, i.isMultiple(of: 2) ? .goal : .saved)
        }
        XCTAssertEqual(state.winner, .one); XCTAssertEqual(state.goals(.one), 5)
        XCTAssertEqual(state.goals(.two), 0)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: state.shots.map(\.json)))
    }
    func testDeadlineGraceAndTimeoutProgression() {
        var timely = WallGoalDuel(), late = timely
        let end = timely.deadline
        XCTAssertNotNil(timely.hit(point: CGPoint(x: 0.4, y: 0.4), footprint: ball, contact: end - 0.01, now: end + 0.4))
        XCTAssertNil(late.hit(point: CGPoint(x: 0.4, y: 0.4), footprint: ball, contact: end + 0.01, now: end + 0.4))
        for i in 1...10 {
            late.advance(at: late.deadline + 0.81)
            XCTAssertEqual(late.shots.count, i)
            XCTAssertEqual(late.shots.last?.outcome, .timeout)
        }
        XCTAssertTrue(late.finished); XCTAssertNil(late.winner)
    }
    func testInvalidFootprintAndTimesDoNotConsumeShot() {
        var state = WallGoalDuel()
        let p = CGPoint(x: 0.4, y: 0.4), invalid = WallContactFootprint(xAxis: .zero, yAxis: .zero)
        XCTAssertNil(state.hit(point: p, footprint: invalid, contact: 1, now: 1.2))
        XCTAssertNil(state.hit(point: p, footprint: ball, contact: .nan, now: 1.2))
        XCTAssertNil(state.hit(point: p, footprint: ball, contact: 1, now: .infinity))
        XCTAssertNil(state.hit(point: p, footprint: ball, contact: 2, now: 1.2))
        XCTAssertTrue(state.shots.isEmpty)
    }
}

@MainActor
final class WallPartyModelTests: XCTestCase {
    private let host = 1000.0
    private let corners = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                           CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)]
    private func model(_ game: WallGame) -> WallTargetsModel {
        let m = WallTargetsModel(defaults: UserDefaults(suiteName: "PartyTests.\(UUID())")!)
        m.showGameIntro(); XCTAssertTrue(m.selectGame(game)); XCTAssertTrue(m.beginGameSetup())
        XCTAssertTrue(m.setCorners(corners)); m.validateMappingForTest(); XCTAssertTrue(m.finishReference([0.04]))
        XCTAssertTrue(m.startPlay(hostTime: host, seed: 17))
        return m
    }
    private func impact(_ p: CGPoint, time: Double) -> WallImpactDetector.Impact {
        .init(t: host + time, x: 500, y: 300, d: 44, turn: 90, u: p.x, v: p.y,
              box: nil, footprint: WallContactFootprint(xAxis: CGPoint(x: 0.04, y: 0), yAxis: CGPoint(x: 0, y: 0.04)))
    }
    func testCrossCircleCameraEntryCompletesAndStoresWinnerWithoutSoloHighScore() throws {
        let m = model(.crossCircle)
        for id in [1, 4, 2, 5, 3] {
            let t = m.partyReadyAt + 1, r = m.game.layout.target(id)!.frame
            XCTAssertTrue(m.accept(impact(CGPoint(x: r.midX, y: r.midY), time: t), hostTime: host + t + 0.2) { _ in })
        }
        XCTAssertEqual(m.partyWinner, .one); XCTAssertTrue(m.sessionEnded)
        XCTAssertEqual(m.gameScreen, .results); XCTAssertEqual(m.hits.count, 5)
        XCTAssertEqual(m.bestArcadeScore, 0)
        XCTAssertEqual(m.gameMetadata["winner"] as? Int, 1)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: m.gameMetadata))
        m.newRound(); XCTAssertNil(m.crossCircle); XCTAssertFalse(m.partyFinished)
    }
    func testGoalTenShotsEndSessionAndRecordSavedAsWellAsGoals() throws {
        let m = model(.goalDuel)
        for i in 0..<10 {
            let t = m.partyReadyAt + 1, head = m.goalDuel!.keeper(at: t)[0].frame
            let p = i.isMultiple(of: 2) ? CGPoint(x: 0.4, y: 0.4) : CGPoint(x: head.midX, y: head.midY)
            XCTAssertTrue(m.accept(impact(p, time: t), hostTime: host + t + 0.2) { _ in })
        }
        XCTAssertTrue(m.sessionEnded); XCTAssertEqual(m.partyWinner, .one)
        XCTAssertEqual(m.goalDuel?.shots.count, 10); XCTAssertEqual(m.hits.count, 10)
        XCTAssertEqual(m.gameMetadata["playerGoals"] as? [Int], [5, 0])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: m.gameMetadata))
    }
    func testGoalAlignmentPauseFreezesKeeperDeadlineAndHandover() {
        let m = model(.goalDuel)
        m.applyAlignment(.init(status: .obscured, corners: corners, revision: 1), hostTime: host + 2)
        let pose = m.goalDuel!.keeper(at: m.arcadeTime(at: host + 2))
        m.tickArcade(hostTime: host + 100)
        XCTAssertEqual(m.arcadeTime(at: host + 100), 2)
        XCTAssertEqual(m.goalDuel!.keeper(at: m.arcadeTime(at: host + 100)), pose)
        XCTAssertTrue(m.goalDuel!.shots.isEmpty)
        XCTAssertFalse(m.accept(impact(CGPoint(x: 0.4, y: 0.4), time: 100), hostTime: host + 100.1) { _ in })
        m.applyAlignment(.init(status: .ready, corners: corners, revision: 1), hostTime: host + 100)
        XCTAssertTrue(m.accept(impact(CGPoint(x: 0.4, y: 0.4), time: 101), hostTime: host + 101.2) { _ in })
        XCTAssertEqual(m.goalDuel?.shots.count, 1)
    }
    func testTimeoutOnlyMatchStillFinishesForAutomaticRecordingSave() {
        let m = model(.goalDuel)
        for _ in 0..<10 { m.tickArcade(hostTime: host + m.goalDuel!.deadline + 0.81) }
        XCTAssertTrue(m.partyFinished); XCTAssertTrue(m.sessionEnded)
        XCTAssertEqual(m.gameScreen, .results); XCTAssertNil(m.partyWinner)
    }
    func testGameCannotSwitchWhileRecordingAndRematchNeedsNewSetup() {
        let m = model(.crossCircle)
        m.recordingState = .recording
        XCTAssertFalse(m.selectGame(.goalDuel))
        m.finishSession(); m.recordingState = .saving
        XCTAssertFalse(m.selectGame(.goalDuel)); XCTAssertFalse(m.beginGameSetup())
        m.recordingState = .saved
        XCTAssertTrue(m.selectGame(.goalDuel)); XCTAssertNil(m.crossCircle)
        XCTAssertEqual(m.calibration, .required)
        XCTAssertFalse(m.startPlay(hostTime: host + 200))
    }
}
#endif
