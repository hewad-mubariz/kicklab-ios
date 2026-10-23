import XCTest
@testable import kicklab

/// The best streak ranks, never the session total. A touch the counter left out can be
/// asked about; if it was confirmed it would count, and a stop it was would join two runs.
final class LeaderboardCorrectionTests: XCTestCase {
    private func moment(_ kind: LeaderboardReviewMoment.Kind, at time: Int) -> LeaderboardReviewMoment {
        LeaderboardReviewMoment(kind: kind, timeMS: time, lastTimeMS: time, clipStartMS: time - 1_000, clipEndMS: time + 1_200)
    }

    /// A hand release, 30 touches with 3 of them unsure, a hand stop, then 20 more with
    /// one unsure: 51 in all.
    private func session() -> LeaderboardCorrection {
        let leftOut = [5_200, 9_400, 12_400]
        let first = stride(from: 1_000, to: 19_000, by: 600).filter { !leftOut.contains($0) }
        let second = stride(from: 21_000, to: 21_000 + 20 * 600, by: 600).map { $0 }
        let moments = [moment(.handContact, at: 400), moment(.handsUncertain, at: 5_200), moment(.lowContactUncertain, at: 9_400),
                       moment(.bodyUncertain, at: 12_400), moment(.continuityGap, at: 19_500),
                       moment(.handContact, at: 20_000), moment(.ballUncertain, at: 24_300)]
        let review = LeaderboardTouchReview(version: 1, durationMS: 40_000, complete: true, moments: moments)
        XCTAssertEqual(first.count + second.count + leftOut.count, 50)
        return LeaderboardCorrection(review: review, touchTimesMS: first + second, durationMS: 40_000)
    }

    func testTheStreakStartsAtTheFirstCountedTouchAndRanksNotTheTotal() {
        let correction = session()
        XCTAssertEqual(correction.counted?.count, 27, "The hand release doesn't count; unsure touches neither count nor end it")
        XCTAssertEqual(correction.endedBy?.timeMS, 20_000, "The hand stop after the run ended it, not the release before it")
    }

    func testOnlyUnsureTouchesInsideTheStreakCanBeSent() {
        let correction = session()
        XCTAssertEqual(correction.leftOut.map(\.timeMS), [5_200, 9_400, 12_400])
        XCTAssertFalse(correction.leftOut.contains { $0.kind.breaksStreak }, "Clear hand, hold and ground calls are final")
        XCTAssertFalse(correction.leftOut.contains { $0.kind == .continuityGap })
        XCTAssertFalse(correction.leftOut.contains { $0.timeMS == 24_300 }, "Unsure touches outside the streak aren't offered")
    }

    func testConfirmedLeftOutTouchesLengthenTheStreak() {
        let correction = session()
        XCTAssertEqual(correction.streak(counting: Set(correction.leftOut.map(\.id)))?.count, 30)
        XCTAssertEqual(correction.streak(counting: [correction.leftOut[0].id])?.count, 28)
        let stop = correction.review.moments.first { $0.timeMS == 20_000 }!.id
        XCTAssertEqual(correction.streak(counting: [stop])?.count, 27, "A stop can't be asked about")
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

    func testAnOpenCheckShowsBesideTheScoreThatStillRanks() {
        let ranked = UUID(), other = UUID()
        let you = LeaderboardEntry(rank: 11, name: "Alex", touches: 27, isYou: true, sessionID: ranked)
        let sameSession = LeaderboardOpenCheck(sessionID: ranked, touches: 3, count: 30, sending: false)
        XCTAssertEqual(sameSession.label(beside: 27, ranked: ranked), "3 in review · 30 if confirmed")
        XCTAssertEqual(LeaderboardOpenCheck(sessionID: ranked, touches: 3, count: 30, sending: true).label(beside: 27, ranked: ranked),
                       "3 waiting to send · 30 if confirmed")
        let bigger = LeaderboardOpenCheck(sessionID: other, touches: 2, count: 34, sending: false)
        XCTAssertEqual(bigger.label(beside: 27, ranked: ranked), "A 34 is in review")
        XCTAssertNil(LeaderboardOpenCheck(sessionID: other, touches: 2, count: 20, sending: false).label(beside: 27, ranked: ranked),
                     "A check that couldn't raise the score isn't shown")
        XCTAssertEqual([bigger, sameSession].beside(you), sameSession, "The session that ranks comes first")
        XCTAssertEqual([bigger].beside(you), bigger)
        XCTAssertNil([sameSession].beside(LeaderboardEntry(rank: 1, name: "Leo", touches: 40)), "Only your own row")
    }
}
