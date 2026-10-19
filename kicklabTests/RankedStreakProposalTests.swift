import XCTest
@testable import kicklab

final class RankedStreakProposalTests: XCTestCase {
    func testProposalChoosesOneRunInsteadOfTotalSessionTouches() throws {
        let result = try XCTUnwrap(RankedStreakProposal.suggest(touchTimes: [1,2,3,4,5,6],
            boundaries: [3.5], duration: 8))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.startMS, 850, "Equal runs retain the earlier segment")
        XCTAssertEqual(result.endMS, 3150)
        XCTAssertTrue(result.isValid(durationMS: 8000))
    }
    func testLongGapDuplicatesAndInvalidTimesCannotInflateSuggestion() throws {
        let result = try XCTUnwrap(RankedStreakProposal.suggest(touchTimes: [.nan,-1,1,1,2,8,8.5,9,99],
            boundaries: [.infinity], duration: 10))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.startMS, 7850)
        XCTAssertEqual(result.endMS, 9150)
        XCTAssertNil(RankedStreakProposal.suggest(touchTimes: [1], boundaries: [], duration: .infinity))
        XCTAssertNil(RankedStreakProposal.suggest(touchTimes: [], boundaries: [], duration: 10))
    }
    func testSegmentCannotExtendBeyondOriginalOrHaveNoContacts() {
        XCTAssertFalse(RankedStreakProposal(count: 0, startMS: 0, endMS: 100).isValid(durationMS: 100))
        XCTAssertFalse(RankedStreakProposal(count: 1, startMS: 50, endMS: 50).isValid(durationMS: 100))
        XCTAssertFalse(RankedStreakProposal(count: 1, startMS: 0, endMS: 101).isValid(durationMS: 100))
        XCTAssertTrue(RankedStreakProposal(count: 1, startMS: 0, endMS: 100).isValid(durationMS: 100))
    }
    func testWeeklyResetIsMondayUTCThroughDaylightSavingChange() throws {
        let formatter = ISO8601DateFormatter()
        let sunday = try XCTUnwrap(formatter.date(from: "2026-10-25T23:30:00Z"))
        let monday = try XCTUnwrap(formatter.date(from: "2026-10-26T00:00:00Z"))
        XCTAssertEqual(LeaderboardRules.nextReset(after: sunday), monday)
        XCTAssertEqual(LeaderboardRules.nextReset(after: monday).timeIntervalSince(monday), 7*24*3600)
    }
}
