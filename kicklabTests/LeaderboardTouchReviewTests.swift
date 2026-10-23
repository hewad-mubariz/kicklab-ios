import XCTest
@testable import kicklab

final class LeaderboardTouchReviewTests: XCTestCase {
    private func event(_ time: Double, _ reason: RejectionReason?, hand: Bool = false,
                       body: RestrictedTouchPolicy.Failure? = nil) -> TouchDebugEvent {
        .init(frameIndex: Int(time * 30), time: time, rejection: reason, handConfirmed: hand, bodyFailure: body, ball: nil)
    }
    func testNoiseDoesNotFlagOrSplitAndUncertainHandsDoNotBecomeAHandTouch() throws {
        var evidence = TouchReviewEvidence()
        for reason: RejectionReason in [.cooldown, .amplitudeTooSmall, .insufficientImpulse] { evidence.append(event(2, reason)) }
        evidence.append(event(2.5, .disallowedBodyContact, body: .handsUncertain))
        evidence.append(event(4.5, .disallowedBodyContact, body: .missingPose))
        let report = try XCTUnwrap(LeaderboardTouchReview.make(evidence: evidence, touchTimes: [1,2,3,4,5], duration: 6))
        XCTAssertEqual(report.moments.map(\.kind), [.handsUncertain, .bodyUncertain])
        XCTAssertTrue(report.streakBoundaries.isEmpty)
        XCTAssertEqual(RankedStreakProposal.suggest(touchTimes: [1,2,3,4,5], boundaries: report.streakBoundaries, duration: 6)?.count, 5)
    }
    func testOnlyCorroboratedGroundAndPositiveHandEvidenceSplitTheProposal() throws {
        var evidence = TouchReviewEvidence()
        evidence.append(event(1.5, .groundBounce))
        evidence.append(event(3.5, .groundBounce), groundConfirmed: true)
        evidence.append(event(5.5, .disallowedBodyContact, hand: true, body: .handsNearBall))
        evidence.append(event(7.5, .heldBall))
        let times: [Double] = [1,2,3,4,5,6,7,8]
        let report = try XCTUnwrap(LeaderboardTouchReview.make(evidence: evidence, touchTimes: times, duration: 9))
        XCTAssertEqual(report.moments.map(\.kind), [.lowContactUncertain, .groundContact, .handContact, .heldBall])
        XCTAssertEqual(RankedStreakProposal.suggest(touchTimes: times, boundaries: report.streakBoundaries, duration: 9)?.count, 3)
    }
    func testNearbyReportsGroupButCountedTouchSeparatesContacts() throws {
        var evidence = TouchReviewEvidence()
        for time in [1.0,1.1,1.2,1.4] { evidence.append(event(time, .disallowedBodyContact, body: .missingPose)) }
        let report = try XCTUnwrap(LeaderboardTouchReview.make(evidence: evidence, touchTimes: [1.3], duration: 2))
        XCTAssertEqual(report.moments.count, 2)
        XCTAssertEqual(report.moments[0].lastTimeMS, 1200)
        XCTAssertEqual(report.moments[0].clipStartMS, 0)
        XCTAssertEqual(report.moments[0].clipEndMS, 2000)
    }
    func testLongGapIsReviewEvidenceRatherThanAProvenDrop() throws {
        let report = try XCTUnwrap(LeaderboardTouchReview.make(evidence: .init(), touchTimes: [1,2,8,9], duration: 10))
        XCTAssertEqual(report.moments.map(\.kind), [.continuityGap])
        XCTAssertTrue(report.streakBoundaries.isEmpty)
        XCTAssertEqual(RankedStreakProposal.suggest(touchTimes: [1,2,8,9], boundaries: report.streakBoundaries, duration: 10)?.count, 4)
    }
    func testEvidenceLimitIsExplicitAndUsesRecordingRelativeTime() throws {
        var evidence = TouchReviewEvidence(limit: 2)
        for time in [100.5,101,102] { evidence.append(event(time, .handContact)) }
        let report = try XCTUnwrap(LeaderboardTouchReview.make(evidence: evidence.relative(to: 100), touchTimes: [], duration: 3))
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.moments.map(\.timeMS), [500,1000])
        XCTAssertEqual(try JSONDecoder().decode(LeaderboardTouchReview.self, from: JSONEncoder().encode(report)), report)
    }
    func testOldHistoryDecodesWithoutEvidenceAndNewHistoryRetainsIt() throws {
        var item = HistorySession(id: UUID(), ownerID: UUID(), touches: 4, durationMS: 5000,
            source: .recording, completedAt: Date(), syncState: .synced)
        let old = try JSONEncoder().encode(item)
        XCTAssertNil(try JSONDecoder().decode(HistorySession.self, from: old).touchReview)
        var evidence = TouchReviewEvidence(); evidence.append(event(2, .handContact))
        item.touchReview = LeaderboardTouchReview.make(evidence: evidence, touchTimes: [1,3,4], duration: 5)
        XCTAssertEqual(try JSONDecoder().decode(HistorySession.self, from: JSONEncoder().encode(item)), item)
    }
    func testInvalidTimesAreDiscardedAndReportNeverExtendsBeyondVideo() throws {
        var evidence = TouchReviewEvidence()
        evidence.append(event(0, .handContact)); evidence.append(event(1, .heldBall))
        let report = try XCTUnwrap(LeaderboardTouchReview.make(evidence: evidence, touchTimes: [.nan,-1,2], duration: 1))
        XCTAssertEqual(report.moments.last?.clipEndMS, 1000)
        XCTAssertNil(LeaderboardTouchReview.make(evidence: evidence, touchTimes: [], duration: .infinity))
    }
}
