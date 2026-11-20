#if WALL_GAMES_PREVIEW
import XCTest
import UIKit
@testable import kicklab

@MainActor final class WallArcadeProductTests: XCTestCase {
    func testReleaseCatalogueKeepsTopBinsAndHidesGoalDuelAndExperiments() {
        let ids=WallArcadeGame.all.map(\.id)
        XCTAssertEqual(ids.count,9)
        XCTAssertEqual(Set(ids).count,9)
        XCTAssertFalse(ids.contains(WallGame.goalDuel.rawValue))
        XCTAssertTrue(ids.contains("top-bins"))
        XCTAssertFalse(ids.contains("find-space"))
        XCTAssertFalse(ids.contains("virtual-penalties"))
        XCTAssertEqual(WallArcadeGame.all.filter(\.twoPlayers).count,4)
    }
    func testActualGameArtworkIsBundled() {
        for game in WallGame.allCases where game != .clearTheWall {
            let name="arcade-"+game.rawValue.replacingOccurrences(of:"-v1",with:"")
            XCTAssertNotNil(UIImage(named:name),name)
        }
    }
    func testBrickResultIncludesPointsAndActualDestruction() throws {
        let r=try record(["game":WallGame.brickBlast.rawValue,"brickScore":700,"destroyedTargets":Array(1...7),"targetCount":30,"activePlaySeconds":40])
        XCTAssertEqual(r.value,"700");XCTAssertEqual(r.detail,"POINTS · 7/30 BRICKS")
        XCTAssertFalse(r.completed)
    }
    private func record(_ data:[String:Any],video:Bool=false) throws -> WallArcadeRecord {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) }
        try JSONSerialization.data(withJSONObject:data).write(to:folder.appendingPathComponent("session.json"))
        if video { try Data([0]).write(to:folder.appendingPathComponent("video.mov")) }
        return try XCTUnwrap(WallArcadeRecord(folder:folder))
    }
    func testStoppedRoundDoesNotBecomeAWinOrUseSetupDuration() throws {
        let r=try record(["game":WallGame.clearTheWall.rawValue,"status":"completed","duration":90,"activePlaySeconds":12.5,"stopReason":"stop_button"],video:true)
        XCTAssertFalse(r.completed)
        XCTAssertEqual(r.headline,"ROUND STOPPED")
        XCTAssertEqual(r.value,"12.5")
        XCTAssertEqual(r.clock,"0:12")
        XCTAssertNotNil(r.video)
    }
    func testInterruptedRecordingNeverOffersUnfinalizedVideoForSharing() throws {
        let r=try record(["game":WallGame.brickBlast.rawValue,"status":"recording"],video:true)
        XCTAssertFalse(r.finalized)
        XCTAssertNil(r.video)
    }
    func testTopBinsHasOwnScoreAndHistoryRatherThanNumberTargets() throws {
        let shots=(1...5).map { ["shot":$0,"points":100] }
        let r=try record(["game":"top-bins","status":"completed","stopReason":"round_complete","activePlaySeconds":45,
            "challengeEnd":["mode":"top-bins","score":500,"shots":shots]])
        XCTAssertEqual(r.title,"Top Bins")
        XCTAssertNil(r.game)
        XCTAssertEqual(r.value,"500")
        XCTAssertEqual(r.hits,5)
        XCTAssertTrue(r.completed)
    }
    func testPartyWinnerAndDrawRemainDistinct() throws {
        let win=try record(["game":WallGame.goalDuel.rawValue,"partyFinished":true,"winner":2,"playerGoals":[2,4]])
        XCTAssertEqual(win.headline,"PLAYER 2 WINS");XCTAssertEqual(win.value,"2 – 4")
        let draw=try record(["game":WallGame.crossCircle.rawValue,"partyFinished":true])
        XCTAssertEqual(draw.headline,"IT'S A DRAW");XCTAssertEqual(draw.value,"DRAW")
    }
}
#endif
