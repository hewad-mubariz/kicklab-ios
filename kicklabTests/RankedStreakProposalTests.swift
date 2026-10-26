import XCTest
@testable import kicklab

final class RankedStreakProposalTests: XCTestCase {
    func testNinetyTotalRanksLongestFiftyAfterHandAndGroundInterruptions() throws {
        let first = (1...10).map(Double.init)
        let second = (13...62).map(Double.init)
        let third = (65...94).map(Double.init)
        let times = first + second + third
        var evidence = TouchReviewEvidence()
        // Opening hand release and finishing catch must not invalidate a run.
        for (time, kind): (Double, ContactReviewReason) in [(0.5, .handContact), (11, .heldBall), (63, .groundContact), (95, .heldBall)] {
            evidence.append(time: time, kind: kind)
        }
        let review = try XCTUnwrap(LeaderboardTouchReview.make(evidence: evidence, touchTimes: times, duration: 96))
        let result = try XCTUnwrap(RankedStreakProposal.suggest(touchTimes: times,
            boundaries: review.streakBoundaries, duration: 96))
        XCTAssertEqual(times.count, 90)
        XCTAssertEqual(result.count, 50)
        XCTAssertEqual(result.startMS, 12850)
        XCTAssertEqual(result.endMS, 62150)
    }

    func testOpeningHandDropThenUninterruptedRunKeepsEveryValidTouch() throws {
        let times = (1...90).map(Double.init)
        let result = try XCTUnwrap(RankedStreakProposal.suggest(touchTimes: times,
            boundaries: [0, 0.2, 0.6, 91], duration: 92))
        XCTAssertEqual(result.count, 90)
        XCTAssertEqual(result.startMS, 850)
        XCTAssertEqual(result.endMS, 90150)
    }

    func testNewScoresIdentifyStreakFixAndOldStoredVersionIsPreserved() throws {
        let result = try SavedJugglingResult(ownerID: UUID(), touches: 90, duration: 96, source: .recording)
        XCTAssertEqual(result.counterVersion, "juggling-v1-streak-v2")
        let old = try SavedJugglingResult(ownerID: UUID(), touches: 14, duration: 29,
            source: .recording, counterVersion: "juggling-v1")
        let restored = try JSONDecoder().decode(SavedJugglingResult.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(restored.counterVersion, "juggling-v1")
    }
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
        XCTAssertEqual(result.count, 5, "A long gap needs review, not an automatic claim that the ball dropped")
        XCTAssertEqual(result.startMS, 850)
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
