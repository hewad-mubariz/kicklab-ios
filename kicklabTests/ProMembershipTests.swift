import XCTest
@testable import kicklab

final class ProMembershipTests: XCTestCase {
    func testMembershipDecodesWithoutBreakingOlderLeaderboardResponses() throws {
        let base: [String: Any] = ["rank": 4, "touches": 90,
            "user_id": "00000000-0000-0000-0000-000000000001", "display_name": "Alex", "is_you": false]
        for value in [nil, false, true] as [Bool?] {
            var fields = base
            if let value { fields["is_pro"] = value }
            let player = try JSONDecoder().decode(RankedPlayer.self,
                from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertEqual(player.isPro == true, value == true)
            XCTAssertEqual(player.touches, 90)
            XCTAssertEqual(player.rank, 4)
        }
    }
}
