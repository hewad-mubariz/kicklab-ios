#if DEBUG
import XCTest
@testable import kicklab

final class WallBattleRulesTests: XCTestCase {
    private func four(_ columns: [Int]) -> WallFourInRow {
        var s = WallFourInRow()
        for column in columns {
            let t = s.readyAt + 1
            XCTAssertNotNil(s.hit(point: WallFourInRow.centre(column), contact: t, now: t + 0.2))
        }
        return s
    }
    func testFourAllowsNextSeparateShotAfterShortVisibleHandover() {
        var s = WallFourInRow()
        XCTAssertNotNil(s.hit(point: WallFourInRow.centre(1), contact: 1, now: 1.25))
        XCTAssertEqual(s.readyAt, 2.25, accuracy: 0.001)
        XCTAssertNil(s.hit(point: WallFourInRow.centre(2), contact: 1.8, now: 2.4))
        // This cadence was rejected by the former 2.5-second handover.
        XCTAssertNotNil(s.hit(point: WallFourInRow.centre(2), contact: 3.33, now: 3.55))
        XCTAssertEqual(s.drops.count, 2)
        XCTAssertEqual(s.drops.last?.player, .two)
    }

    func testFourWinsInAllDirectionsAndForBothPlayers() {
        let diagonal = [1, 2, 2, 3, 4, 3, 3, 4, 5, 4, 4]
        for seq in [[1, 2, 1, 3, 1, 4, 1], [1, 7, 2, 7, 3, 6, 4], diagonal, diagonal.map { 8 - $0 }] {
            let s = four(seq)
            XCTAssertTrue(s.finished); XCTAssertEqual(s.winner, .one)
            XCTAssertEqual(s.winningLine.count, 4)
        }
        XCTAssertEqual(four([7, 1, 7, 2, 6, 3, 6, 4]).winner, .two)
        XCTAssertEqual(WallFourInRow.lines.count, 69)
        XCTAssertEqual(Set(WallFourInRow.lines).count, 69)
    }
    func testFullBoardDrawAndNoMovesAfterFinish() {
        var s = four([1,2,4,4,6,6,4,1,3,2,2,2,7,1,6,5,3,2,5,2,6,5,5,6,6,1,3,3,3,5,3,7,1,5,7,7,4,4,4,1,7,7])
        XCTAssertTrue(s.finished); XCTAssertNil(s.winner); XCTAssertEqual(s.cells.count, 42)
        let previous = s
        XCTAssertNil(s.hit(point: WallFourInRow.centre(1), contact: 999, now: 999))
        XCTAssertEqual(s, previous)
    }
    func testFullColumnRetryDoesNotConsumeTurnAndChipsStackFromBottom() {
        var s = four([4,4,4,4,4,4])
        XCTAssertEqual(s.drops.map(\.cell), [39,32,25,18,11,4])
        let t = s.readyAt + 1
        XCTAssertNil(s.hit(point: WallFourInRow.centre(4), contact: t, now: t + 0.2))
        XCTAssertEqual(s.player, .one); XCTAssertEqual(s.cells.count, 6)
        XCTAssertEqual(s.events.last?.kind, "column_full")
        XCTAssertNotNil(s.hit(point: WallFourInRow.centre(5), contact: t + 1, now: t + 1.2))
        XCTAssertEqual(s.cells[40], .one)
    }
    func testColumnArrowsAndSeamsMapToExactlyOneColumn() {
        for id in 1...7 {
            let x = WallFourInRow.centre(id).x
            XCTAssertEqual(WallTargetLayout.fourColumns.target(u: x, v: 0.1), id)
            XCTAssertEqual(WallTargetLayout.fourColumns.target(u: x, v: 1.8), id)
        }
        XCTAssertNil(WallTargetLayout.fourColumns.target(u: 0.1, v: 1))
        let x = WallTargetLayout.fourColumns.target(2)!.frame.minX
        XCTAssertEqual(WallTargetLayout.fourColumns.target(u: x, v: 1), 2)
    }
    func testFourRejectsReboundsFutureAndInvalidContacts() {
        var s = four([4])
        let p = WallFourInRow.centre(5), t = s.readyAt
        XCTAssertNil(s.hit(point: p, contact: t - 0.01, now: t + 0.2))
        XCTAssertNil(s.hit(point: p, contact: t + 1, now: t))
        XCTAssertNil(s.hit(point: CGPoint(x: CGFloat.nan, y: 1), contact: t, now: t))
        XCTAssertEqual(s.cells.count, 1)
    }
    func testHexGeometryDoesNotClaimBoundingBoxCornersOrGaps() {
        XCTAssertEqual(WallTerritoryDuel.zones.count, 13)
        for z in WallTerritoryDuel.zones {
            XCTAssertTrue(z.contains(z.centre))
            XCTAssertFalse(z.contains(CGPoint(x: z.centre.x + 0.28, y: z.centre.y + 0.28)))
            XCTAssertTrue(z.vertices.allSatisfy { z.contains($0) })
        }
        // No point may belong to two hexes, including the staggered columns.
        for y in stride(from: 0.0, through: 2.0, by: 0.025) {
            for x in stride(from: 0.0, through: 3.0, by: 0.025) {
                XCTAssertLessThanOrEqual(WallTerritoryDuel.zones.filter { $0.contains(CGPoint(x: x, y: y)) }.count, 1)
            }
        }
    }
    func testTerritoryStealOwnZoneAndMissAllConsumeExactlyOneShot() {
        var s = WallTerritoryDuel()
        func kick(_ p: CGPoint) {
            let t = s.readyAt + 1
            XCTAssertNotNil(s.hit(point: p, contact: t, now: t + 0.2))
        }
        let p = WallTerritoryDuel.zones[0].centre
        kick(p); XCTAssertEqual(s.score(.one), 1)
        kick(p); XCTAssertEqual(s.score(.one), 0); XCTAssertEqual(s.score(.two), 1)
        XCTAssertEqual(s.events.last?.kind, "zone_stolen")
        kick(.zero); XCTAssertEqual(s.events.last?.kind, "zone_missed")
        kick(p); XCTAssertEqual(s.events.last?.kind, "zone_already_owned")
        XCTAssertEqual(s.shots, 4); XCTAssertEqual(s.score(.two), 1)
    }
    func testTerritoryEqualTurnsFinalWinnerAndImmutableFinish() {
        var s = WallTerritoryDuel()
        for i in 0..<20 {
            let t = s.readyAt + 1
            let p = i.isMultiple(of: 2) ? WallTerritoryDuel.zones[(i / 2) % 13].centre : .zero
            XCTAssertNotNil(s.hit(point: p, contact: t, now: t + 0.2))
        }
        XCTAssertTrue(s.finished); XCTAssertEqual(s.winner, .one); XCTAssertEqual(s.score(.one), 10)
        let prior = s
        s.advance(at: 999)
        XCTAssertNil(s.hit(point: .zero, contact: 1000, now: 1000))
        XCTAssertEqual(s, prior)
        XCTAssertEqual(s.events.filter { $0.player == 1 && $0.kind != "match_won" }.count, 10)
        XCTAssertEqual(s.events.filter { $0.player == 2 }.count, 10)
    }
    func testTerritoryTimeoutsDrawAndDelayedContactWithinGrace() {
        var s = WallTerritoryDuel()
        XCTAssertNotNil(s.hit(point: WallTerritoryDuel.zones[0].centre, contact: 19.9, now: 20.4))
        let previous = s.shots
        XCTAssertNil(s.hit(point: .zero, contact: s.readyAt - 0.1, now: s.readyAt + 0.1))
        XCTAssertEqual(s.shots, previous)
        var empty = WallTerritoryDuel()
        for _ in 0..<20 { empty.advance(at: empty.deadline + 0.81) }
        XCTAssertTrue(empty.finished); XCTAssertNil(empty.winner)
    }
    func testCopySetThenExactVisibleBoundaryScoresChallenger() {
        var s = WallCopyMyShot()
        let p = CGPoint(x: 1.5, y: 1)
        XCTAssertNotNil(s.hit(point: p, contact: 1, now: 1.2))
        XCTAssertEqual(s.player, .two); XCTAssertEqual(s.challenges.count, 0)
        let t = s.readyAt + 1
        XCTAssertNotNil(s.hit(point: CGPoint(x: p.x + WallCopyMyShot.radius, y: p.y), contact: t, now: t + 0.2))
        XCTAssertEqual(s.score(.two), 1); XCTAssertEqual(s.score(.one), 0)
        XCTAssertTrue(s.challenges[0].matched)
        XCTAssertEqual(s.player, .two) // Challenger now sets the next spot.
        XCTAssertNil(s.target)
    }
    func testCopyOutsideRingAwardsSetterAndKeepsBothPositions() throws {
        var s = WallCopyMyShot()
        let p = CGPoint(x: 1.5, y: 1)
        s.hit(point: p, contact: 1, now: 1.2)
        let t = s.readyAt + 1, reply = CGPoint(x: 1.751, y: 1)
        s.hit(point: reply, contact: t, now: t + 0.2)
        XCTAssertEqual(s.score(.one), 1); XCTAssertFalse(s.challenges[0].matched)
        XCTAssertEqual(s.challenges[0].target, p); XCTAssertEqual(s.challenges[0].reply, reply)
        XCTAssertEqual(try XCTUnwrap(s.challenges[0].distance), 0.251, accuracy: 1e-8)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: s.challenges.map(\.json)))
    }
    func testCopyOutsideSettingAreaRetriesAndRingFitsBoard() {
        var s = WallCopyMyShot()
        XCTAssertNil(s.hit(point: CGPoint(x: 0.1, y: 1), contact: 1, now: 1.2))
        XCTAssertEqual(s.events.last?.kind, "set_outside_area"); XCTAssertNil(s.target)
        XCTAssertEqual(s.player, .one); XCTAssertEqual(s.deadline, 20)
        XCTAssertGreaterThan(WallCopyMyShot.settingArea.minX, WallCopyMyShot.radius)
        XCTAssertLessThan(WallCopyMyShot.settingArea.maxY + WallCopyMyShot.radius, 2)
    }
    func testCopyReboundCannotBecomeReplyAndNoLatePriorPhaseHit() {
        var s = WallCopyMyShot()
        let p = CGPoint(x: 1.5, y: 1)
        s.hit(point: p, contact: 1, now: 1.2)
        XCTAssertNil(s.hit(point: p, contact: 1, now: 1.3))
        XCTAssertNil(s.hit(point: p, contact: s.readyAt - 0.01, now: s.readyAt + 0.3))
        XCTAssertEqual(s.challenges.count, 0); XCTAssertEqual(s.target, p)
    }
    func testCopySixChallengesThreeSetsEachCanDraw() {
        var s = WallCopyMyShot()
        for _ in 0..<6 {
            var t = s.readyAt + 1
            s.hit(point: CGPoint(x: 1.5, y: 1), contact: t, now: t + 0.2)
            t = s.readyAt + 1
            s.hit(point: CGPoint(x: 1.5, y: 1), contact: t, now: t + 0.2)
        }
        XCTAssertTrue(s.finished); XCTAssertNil(s.winner)
        XCTAssertEqual(s.score(.one), 3); XCTAssertEqual(s.score(.two), 3)
        XCTAssertEqual(s.challenges.filter { $0.setter == .one }.count, 3)
        let prior = s
        s.advance(at: 999)
        XCTAssertNil(s.hit(point: .zero, contact: 999, now: 999))
        XCTAssertEqual(s, prior)
    }
    func testCopySetterAndReplyTimeoutAwardTheOtherPlayer() {
        var s = WallCopyMyShot()
        s.advance(at: 20.81)
        XCTAssertEqual(s.score(.two), 1); XCTAssertEqual(s.events.last?.kind, "setter_timeout")
        let t = s.readyAt + 1
        s.hit(point: CGPoint(x: 1, y: 1), contact: t, now: t + 0.2)
        s.advance(at: s.deadline + 0.81)
        XCTAssertEqual(s.score(.two), 2); XCTAssertEqual(s.events.last?.kind, "reply_timeout")
        for _ in 0..<4 { s.advance(at: s.deadline + 0.81) }
        XCTAssertTrue(s.finished); XCTAssertEqual(s.winner, .two)
    }
    func testTimedBattlesIgnoreNonFiniteAndFutureInputs() {
        var territory = WallTerritoryDuel(), copy = WallCopyMyShot()
        for (contact, now) in [(Double.nan, 1.0), (1.0, .infinity), (2.0, 1.0)] {
            XCTAssertNil(territory.hit(point: CGPoint(x: 1, y: 1), contact: contact, now: now))
            XCTAssertNil(copy.hit(point: CGPoint(x: 1, y: 1), contact: contact, now: now))
        }
        territory.advance(at: .nan); copy.advance(at: .infinity)
        XCTAssertTrue(territory.events.isEmpty); XCTAssertTrue(copy.events.isEmpty)
    }
}

@MainActor
final class WallBattleModelTests: XCTestCase {
    private let host = 1000.0
    private let corners = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                           CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)]
    private func model(_ game: WallGame) -> WallTargetsModel {
        let m = WallTargetsModel(defaults: UserDefaults(suiteName: "BattleTests.\(UUID())")!)
        m.showGameIntro(); XCTAssertTrue(m.selectGame(game)); XCTAssertTrue(m.beginGameSetup())
        XCTAssertTrue(m.setCorners(corners)); m.validateMappingForTest(); XCTAssertTrue(m.finishReference([0.04]))
        XCTAssertTrue(m.startPlay(hostTime: host))
        return m
    }
    @discardableResult
    private func hit(_ m: WallTargetsModel, _ p: CGPoint, time: Double? = nil) -> Bool {
        let t = time ?? (m.partyReadyAt + 1)
        return m.accept(.init(t: host + t, x: 500, y: 300, d: 44, turn: 90,
                             u: p.x, v: p.y, box: nil, footprint: .init(xAxis: CGPoint(x: 0.04, y: 0), yAxis: CGPoint(x: 0, y: 0.04))),
                        hostTime: host + t + 0.2) { _ in }
    }
    func testAllNewGamesFinishThroughCameraEntryAndSaveSerializableResults() throws {
        for game in [WallGame.fourInRow, .territoryDuel, .copyMyShot] {
            let m = model(game)
            if game == .fourInRow {
                for col in [1,2,1,3,1,4,1] { XCTAssertTrue(hit(m, WallFourInRow.centre(col))) }
                XCTAssertEqual(m.partyWinner, .one); XCTAssertEqual(m.hits.count, 7)
            } else if game == .territoryDuel {
                for i in 0..<20 { XCTAssertTrue(hit(m, i.isMultiple(of: 2) ? WallTerritoryDuel.zones[i / 2].centre : .zero)) }
                XCTAssertEqual(m.partyWinner, .one); XCTAssertEqual(m.partyScore(.one), 10)
            } else {
                for _ in 0..<6 {
                    XCTAssertTrue(hit(m, CGPoint(x: 1.5, y: 1))); XCTAssertTrue(hit(m, CGPoint(x: 1.5, y: 1)))
                }
                XCTAssertNil(m.partyWinner); XCTAssertEqual(m.partyScore(.one), 3)
            }
            XCTAssertTrue(m.sessionEnded); XCTAssertTrue(m.partyFinished)
            XCTAssertEqual(m.gameScreen, .results); XCTAssertEqual(m.bestArcadeScore, 0)
            XCTAssertEqual(m.gameMetadata["partyFinished"] as? Bool, true)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: m.gameMetadata))
            m.newRound()
            XCTAssertFalse(m.partyFinished); XCTAssertNil(m.fourInRow); XCTAssertNil(m.territoryDuel); XCTAssertNil(m.copyMyShot)
        }
    }
    func testAlignmentPauseFreezesBothTimedGamesAndRejectsPausedContacts() {
        for game in [WallGame.territoryDuel, .copyMyShot] {
            let m = model(game)
            m.applyAlignment(.init(status: .obscured, corners: corners, revision: 1), hostTime: host + 2)
            m.tickArcade(hostTime: host + 100)
            XCTAssertEqual(m.arcadeTime(at: host + 100), 2); XCTAssertTrue(m.arcadeEvents.isEmpty)
            XCTAssertFalse(hit(m, CGPoint(x: 1.5, y: 1), time: 50))
            m.applyAlignment(.init(status: .ready, corners: corners, revision: 1), hostTime: host + 100)
            XCTAssertTrue(hit(m, CGPoint(x: 1.5, y: 1), time: 101))
            XCTAssertFalse(m.sessionEnded)
        }
    }
    func testTimeoutOnlyGamesEndForAutomaticSave() {
        for game in [WallGame.territoryDuel, .copyMyShot] {
            let m = model(game)
            while !m.sessionEnded {
                let deadline = m.territoryDuel?.deadline ?? m.copyMyShot!.deadline
                m.tickArcade(hostTime: host + deadline + 0.81)
            }
            XCTAssertTrue(m.partyFinished); XCTAssertNil(m.partyWinner)
            XCTAssertEqual(m.gameScreen, .results)
        }
    }
    func testNoGameSwitchWhileRecordingOrSavingAndNewSetupRequired() {
        let m = model(.fourInRow)
        m.recordingState = .recording; XCTAssertFalse(m.selectGame(.territoryDuel))
        m.finishSession(); m.recordingState = .saving; XCTAssertFalse(m.selectGame(.copyMyShot))
        m.recordingState = .saved; XCTAssertTrue(m.selectGame(.copyMyShot))
        XCTAssertNil(m.fourInRow); XCTAssertEqual(m.calibration, .required)
        XCTAssertFalse(m.startPlay(hostTime: host + 200))
    }
}
#endif
