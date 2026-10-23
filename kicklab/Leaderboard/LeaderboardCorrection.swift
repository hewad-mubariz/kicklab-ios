import Foundation

/// What a player can ask a reviewer to count in one recorded session. Every flagged
/// moment except a gap is a touch the counter turned down: an unsure one was left out
/// of the streak, a hand, hold or ground call ended it. Asking about a moment means
/// "this was a valid touch", so it is counted and, if it ended the streak, joins it.
nonisolated struct LeaderboardCorrection: Equatable, Sendable {
    let review: LeaderboardTouchReview
    let touchTimesMS: [Int]
    let durationMS: Int

    init?(item: HistorySession) {
        guard let review = item.touchReview, let times = item.touchTimesMS else { return nil }
        self.review = review; touchTimesMS = times; durationMS = item.durationMS
    }

    init(review: LeaderboardTouchReview, touchTimesMS: [Int], durationMS: Int) {
        self.review = review; self.touchTimesMS = touchTimesMS; self.durationMS = durationMS
    }

    /// Touches left out of the streak without ending it.
    var leftOut: [LeaderboardReviewMoment] { review.moments.filter { $0.kind != .continuityGap && !$0.kind.breaksStreak } }
    /// Calls that ended a streak.
    var stops: [LeaderboardReviewMoment] { review.moments.filter(\.kind.breaksStreak) }
    var askable: [LeaderboardReviewMoment] { review.moments.filter { $0.kind != .continuityGap } }

    /// The device's streak, with nothing asked about.
    var counted: RankedStreakProposal? { streak(counting: []) }

    /// The best streak if every chosen moment were confirmed as a touch.
    func streak(counting chosen: Set<LeaderboardReviewMoment.ID>) -> RankedStreakProposal? {
        let picked = askable.filter { chosen.contains($0.id) }
        let touches = (touchTimesMS + picked.map(\.timeMS)).map { Double($0) / 1000 }
        let boundaries = stops.filter { !chosen.contains($0.id) }
            .flatMap { [Double($0.timeMS) / 1000, Double($0.lastTimeMS) / 1000] }
        return RankedStreakProposal.suggest(touchTimes: touches, boundaries: boundaries,
                                            duration: Double(durationMS) / 1000)
    }

    /// What is sent with the request: only the chosen moments, so the clips show exactly those.
    func request(counting chosen: Set<LeaderboardReviewMoment.ID>) -> LeaderboardTouchReview {
        LeaderboardTouchReview(version: review.version, durationMS: review.durationMS, complete: review.complete,
                               moments: askable.filter { chosen.contains($0.id) })
    }
}
