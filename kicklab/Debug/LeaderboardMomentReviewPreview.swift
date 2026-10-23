#if DEBUG
import SwiftUI

/// Isolated UI fixture; these flags are examples, not analysis of the supplied video.
struct LeaderboardMomentReviewPreview: View {
    let url: URL
    private let report = LeaderboardTouchReview(version: 1, durationMS: 25_000, complete: true, moments: [
        .init(kind: .handsUncertain, timeMS: 2_000, lastTimeMS: 2_100, clipStartMS: 1_000, clipEndMS: 3_300),
        .init(kind: .lowContactUncertain, timeMS: 8_000, lastTimeMS: 8_000, clipStartMS: 7_000, clipEndMS: 9_200),
        .init(kind: .handContact, timeMS: 15_000, lastTimeMS: 15_000, clipStartMS: 14_000, clipEndMS: 16_200)
    ])
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Preview only · example flags, no upload or score submission.") }
                LeaderboardTouchReviewSection(report: report, videoURL: url)
            }.navigationTitle("Leaderboard review")
        }
    }
}

/// A session with left-out touches and a hand stop, for checking the correction screen.
struct LeaderboardCorrectionPreview: View {
    let url: URL
    @StateObject private var review = LeaderboardReviewStore(service: nil,
        root: FileManager.default.temporaryDirectory.appendingPathComponent("correction-preview"))
    private var item: HistorySession {
        // 27 counted touches, 3 left out among them, a hand stop, then 17 more.
        let leftOut = [5_200, 9_400, 12_400]
        let first = stride(from: 1_000, through: 18_400, by: 600).filter { !leftOut.contains($0) }
        let second = stride(from: 20_000, through: 29_600, by: 600).map { $0 }
        let moments = leftOut.enumerated().map { index, time in
            LeaderboardReviewMoment(kind: [.handsUncertain, .lowContactUncertain, .bodyUncertain][index], timeMS: time,
                lastTimeMS: time, clipStartMS: time - 1_000, clipEndMS: time + 1_200)
        } + [LeaderboardReviewMoment(kind: .handContact, timeMS: 19_100, lastTimeMS: 19_200, clipStartMS: 18_100, clipEndMS: 20_400)]
        var item = HistorySession(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!, ownerID: UUID(),
            touches: first.count + second.count, durationMS: 30_000, source: .recording, completedAt: Date(), syncState: .synced)
        item.touchTimesMS = first + second
        item.touchReview = LeaderboardTouchReview(version: 1, durationMS: 30_000, complete: true, moments: moments)
        item.rankedProposal = LeaderboardCorrection(item: item)?.counted
        return item
    }
    var body: some View {
        NavigationStack { LeaderboardCorrectionForm(item: item, video: url, review: review) }
    }
}
#endif
