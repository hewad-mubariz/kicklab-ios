import Foundation

/// What a player can ask a reviewer to count in one recorded session. A streak starts
/// at the first counted touch, so a hand release before it never matters, and ends at a
/// hand, hold or ground call. Those calls are clear and final. Only touches the counter
/// wasn't sure of, inside the streak, can be sent: confirming one counts it.
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

    /// The device's streak, with nothing asked about.
    var counted: RankedStreakProposal? { streak(adding: []) }

    /// From the streak's first counted touch to its last.
    private var span: ClosedRange<Int>? {
        guard let streak = counted else { return nil }
        let inside = touchTimesMS.filter { $0 >= streak.startMS && $0 <= streak.endMS }
        guard let first = inside.min(), let last = inside.max() else { return nil }
        return first...last
    }

    /// Touches the counter wasn't sure of, inside the streak. They didn't count and didn't end it.
    var leftOut: [LeaderboardReviewMoment] {
        guard let span else { return [] }
        return review.moments.filter {
            $0.kind != .continuityGap && !$0.kind.breaksStreak && span.contains($0.timeMS) && span.contains($0.lastTimeMS)
        }
    }

    /// The call that ended the streak, if one did rather than the recording stopping.
    var endedBy: LeaderboardReviewMoment? {
        guard let span else { return nil }
        return review.moments.filter { $0.kind.breaksStreak && $0.timeMS >= span.upperBound }.min { $0.timeMS < $1.timeMS }
    }

    /// The best streak if every chosen touch were confirmed.
    func streak(counting chosen: Set<LeaderboardReviewMoment.ID>) -> RankedStreakProposal? {
        streak(adding: leftOut.filter { chosen.contains($0.id) })
    }

    private func streak(adding picked: [LeaderboardReviewMoment]) -> RankedStreakProposal? {
        let touches = (touchTimesMS + picked.map(\.timeMS)).map { Double($0) / 1000 }
        return RankedStreakProposal.suggest(touchTimes: touches, boundaries: review.streakBoundaries,
                                            duration: Double(durationMS) / 1000)
    }

    /// What is sent with the request: only the chosen moments, so the clips show exactly those.
    func request(counting chosen: Set<LeaderboardReviewMoment.ID>) -> LeaderboardTouchReview {
        LeaderboardTouchReview(version: review.version, durationMS: review.durationMS, complete: review.complete,
                               moments: leftOut.filter { chosen.contains($0.id) })
    }
}

/// A touch check not decided yet. Until it is, your score stays the device's streak,
/// and the leaderboard shows the check beside it.
nonisolated struct LeaderboardOpenCheck: Equatable, Sendable {
    let sessionID: UUID
    /// Touches asked about.
    let touches: Int
    /// The streak if every one is confirmed.
    let count: Int
    /// Still on this phone, not with a reviewer yet.
    let sending: Bool

    /// What your row says beside a score of `score` from session `ranked`.
    /// Nothing shows when confirming it couldn't raise the score.
    func label(beside score: Int, ranked: UUID?) -> String? {
        guard count > score else { return nil }
        if ranked == nil || ranked == sessionID {
            return sending ? "\(touches) waiting to send · \(count) if confirmed"
                           : "\(touches) in review · \(count) if confirmed"
        }
        // A check on another session of yours that could beat this one.
        return sending ? "A \(count) is waiting to send" : "A \(count) is in review"
    }
}

extension LeaderboardReviewStore {
    /// Checks waiting on this phone or with a reviewer.
    var openChecks: [LeaderboardOpenCheck] {
        let waiting = queued.map {
            LeaderboardOpenCheck(sessionID: $0.sessionID, touches: $0.request?.moments.count ?? 0,
                                 count: $0.proposal.count, sending: true)
        }
        let sent = attempts.filter { ($0.status == .pending || $0.status == .uploading) && !isQueued($0.sessionID) }.map {
            LeaderboardOpenCheck(sessionID: $0.sessionID, touches: $0.touchReview?.moments.count ?? 0,
                                 count: $0.proposedCount, sending: $0.status == .uploading)
        }
        return waiting + sent
    }

    func openCheck(for entry: LeaderboardEntry) -> LeaderboardOpenCheck? { openChecks.beside(entry) }
}

extension [LeaderboardOpenCheck] {
    /// The check to show beside your score: the one on the session that ranks, else
    /// the one that would raise it most.
    func beside(_ entry: LeaderboardEntry) -> LeaderboardOpenCheck? {
        guard entry.isYou else { return nil }
        if let ranked = entry.sessionID, let same = first(where: { $0.sessionID == ranked }) { return same }
        return filter { $0.count > entry.touches }.max { $0.count < $1.count }
    }
}
