import XCTest
@testable import kicklab

final class PlayerGroundEstimateTests: XCTestCase {
    private let full = PersonBox(x:0.5,y:0.69,width:0.4,height:0.6)
    private let partial = PersonBox(x:0.5,y:0.59,width:0.2,height:0.4)
    private func player(_ box: PersonBox?, state: ActivePlayerSelection.State = .locked, id: Int = 1) -> ActivePlayerSelection {
        .init(state:state,id:id,box:box,observed:state == .locked,peopleCount:2)
    }
    func testOccludedBoxesDoNotMoveOrRefreshFloor() {
        var ground = PlayerGroundEstimate()
        XCTAssertEqual(ground.update(player:player(full),timestampMs:0),0.99)
        XCTAssertEqual(ground.update(player:player(partial,state:.obscured),timestampMs:300),0.99)
        XCTAssertEqual(ground.update(player:player(nil,state:.obscured),timestampMs:900),0.99)
        XCTAssertNil(ground.update(player:player(partial,state:.obscured),timestampMs:1300))
    }
    func testLockedTruncatedLegsDoNotBecomeFloorEvenAfterExpiry() {
        var ground = PlayerGroundEstimate()
        _ = ground.update(player:player(full),timestampMs:0)
        for t in [100,300,600,900] { XCTAssertEqual(ground.update(player:player(partial),timestampMs:t),0.99) }
        XCTAssertNil(ground.update(player:player(partial),timestampMs:1300))
        XCTAssertEqual(ground.update(player:player(full),timestampMs:1400),0.99)
    }
    func testCrouchAndGradualPerspectiveMovementRemainUsable() throws {
        var ground = PlayerGroundEstimate()
        _ = ground.update(player:player(full),timestampMs:0)
        let crouch = PersonBox(x:0.5,y:0.79,width:0.4,height:0.4)
        XCTAssertEqual(ground.update(player:player(crouch),timestampMs:100),0.99)
        let away = PersonBox(x:0.5,y:0.73,width:0.35,height:0.38)
        XCTAssertEqual(try XCTUnwrap(ground.update(player:player(away),timestampMs:200)),0.92,accuracy:1e-12)
    }
    func testNewIdentityAndClockDiscontinuityDoNotBorrowOldFloor() {
        var ground = PlayerGroundEstimate()
        _ = ground.update(player:player(full),timestampMs:100)
        XCTAssertNil(ground.update(player:player(nil,state:.obscured,id:2),timestampMs:200))
        _ = ground.update(player:player(full),timestampMs:300)
        XCTAssertNil(ground.update(player:player(nil,state:.obscured),timestampMs:10))
        _ = ground.update(player:player(full),timestampMs:100)
        XCTAssertNil(ground.update(player:player(nil,state:.obscured),timestampMs:2000))
    }
    func testHistoricalConfigurationDoesNotOptIntoNewFloor() throws {
        let data = try JSONEncoder().encode(CounterConfig())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        object.removeValue(forKey:"stabilizesPlayerGround")
        let historical = try JSONDecoder().decode(CounterConfig.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(historical.stabilizesPlayerGround)
    }
}
