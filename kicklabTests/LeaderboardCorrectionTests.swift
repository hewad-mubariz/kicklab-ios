import XCTest
@testable import kicklab

/// The best streak ranks, never the session total. A touch the counter left out can be
/// asked about; if it was confirmed it would count, and a stop it was would join two runs.
final class LeaderboardCorrectionTests: XCTestCase {
    private func moment(_ kind: LeaderboardReviewMoment.Kind, at time: Int) -> LeaderboardReviewMoment {
        LeaderboardReviewMoment(kind: kind, timeMS: time, lastTimeMS: time, clipStartMS: time - 1_000, clipEndMS: time + 1_200)
    }

    /// 30 touches with 3 of them left out, a hand stop, then 20 more: 50 in all.
    private func session() -> LeaderboardCorrection {
        let leftOut = [5_200, 9_400, 12_400]
        let first = stride(from: 1_000, to: 19_000, by: 600).filter { !leftOut.contains($0) }
        let second = stride(from: 21_000, to: 21_000 + 20 * 600, by: 600).map { $0 }
        let moments = [moment(.handsUncertain, at: 5_200), moment(.lowContactUncertain, at: 9_400),
                       moment(.bodyUncertain, at: 12_400), moment(.handContact, at: 20_000),
                       moment(.continuityGap, at: 19_500)]
        let review = LeaderboardTouchReview(version: 1, durationMS: 40_000, complete: true, moments: moments)
        XCTAssertEqual(first.count + second.count + leftOut.count, 50)
        return LeaderboardCorrection(review: review, touchTimesMS: first + second, durationMS: 40_000)
    }

    func testTheLongestRunRanksNotTheTotal() {
        let correction = session()
        XCTAssertEqual(correction.counted?.count, 27, "Left-out touches neither count nor end the run")
        XCTAssertEqual(correction.leftOut.count, 3)
        XCTAssertEqual(correction.stops.count, 1)
        XCTAssertFalse(correction.askable.contains { $0.kind == .continuityGap }, "A gap is not a touch to ask about")
    }

    func testConfirmedLeftOutTouchesLengthenTheirRun() {
        let correction = session()
        XCTAssertEqual(correction.streak(counting: Set(correction.leftOut.map(\.id)))?.count, 30)
        XCTAssertEqual(correction.streak(counting: [correction.leftOut[0].id])?.count, 28)
    }

    func testAStopJoinsTwoRunsOnlyWhenAskedAbout() {
        let correction = session()
        XCTAssertEqual(correction.streak(counting: [correction.stops[0].id])?.count, 27 + 1 + 20)
        XCTAssertEqual(correction.streak(counting: Set(correction.askable.map(\.id)))?.count, 51)
    }

    func testTheRequestCarriesOnlyTheChosenMoments() {
        let correction = session()
        let chosen = correction.leftOut[1]
        let request = correction.request(counting: [chosen.id])
        XCTAssertEqual(request.moments, [chosen])
        XCTAssertEqual(request.durationMS, 40_000)
    }

    func testOlderSessionsWithoutTouchTimesHaveNothingToAsk() {
        let item = HistorySession(id: UUID(), ownerID: UUID(), touches: 9, durationMS: 9_000, source: .recording,
                                  completedAt: Date(), syncState: .synced)
        XCTAssertNil(LeaderboardCorrection(item: item))
    }

    func testOnlyAStreakTheServerAcceptsIsSaved() throws {
        var result = try SavedJugglingResult(ownerID: UUID(), touches: 5, duration: 10, source: .recording)
        result.rank(.init(count: 7, startMS: 0, endMS: 4_000))
        XCTAssertEqual(result.streak?.count, 5, "Never more than the session's touches")
        result.rank(.init(count: 3, startMS: 0, endMS: 10_001))
        XCTAssertNil(result.streak, "Outside the recording: sync without ranking rather than be refused")
        result.rank(nil)
        XCTAssertNil(result.streak)
    }

    func testResultsSavedByOlderBuildsStillLoad() throws {
        let owner = UUID(), id = UUID()
        let json = """
        {"id":"\(id)","ownerID":"\(owner)","touches":4,"durationMS":5000,"source":"recording",
         "completedAt":0,"appVersion":"1.0","counterVersion":"juggling-v1"}
        """
        let result = try JSONDecoder().decode(SavedJugglingResult.self, from: Data(json.utf8))
        XCTAssertNil(result.streak)
        XCTAssertEqual(result.touches, 4)
    }
}
