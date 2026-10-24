import Foundation

nonisolated enum LeaderboardRules {
    static let version = "beta-1"
    /// Touch checks (sending unsure touches for review) are postponed past the first beta,
    /// which ranks the automatic count only. Turning this on brings back every entry point.
    static let touchChecks = false
    // Matches the deployed project's 50 MiB Storage limit. Raise the app,
    // bucket and database limits together when the hosting plan changes.
    static let maximumVideoBytes: Int64 = 52_428_800
    static let privacy = "Clips are sent only when you ask for a check, and only short ones around the touches you choose, never the whole recording. They are private to you and the review team, are not used for model training and are never shown to other players. Pending and rejected clips expire 30 days after the check or its latest review; confirmed clips are kept until you withdraw the check or delete your account. Withdrawing removes its correction immediately and queues clip deletion within 24 hours."
    static func nextReset(after date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        return calendar.date(byAdding: .day, value: 7, to: start)!
    }
}

/// A proposal is evidence for a reviewer, never a score eligible for publication.
nonisolated struct RankedStreakProposal: Codable, Equatable, Sendable {
    var count: Int
    var startMS: Int
    var endMS: Int
    func isValid(durationMS: Int) -> Bool {
        (1...1_000_000).contains(count) && startMS >= 0 && endMS > startMS && endMS <= durationMS
    }

    /// Split at explicit interruption evidence only. Uncertain visibility and long
    /// gaps need review, not an assumed drop. A reviewer must verify continuity and
    /// can split/join segments or restore contacts missed by the device.
    static func suggest(touchTimes: [Double], boundaries: [Double], duration: Double) -> Self? {
        guard duration.isFinite, duration > 0, duration <= 86_400 else { return nil }
        let times = Array(Set(touchTimes.filter { $0.isFinite && $0 >= 0 && $0 <= duration })).sorted()
        let cuts = boundaries.filter { $0.isFinite && $0 >= 0 && $0 <= duration }.sorted()
        var best: [Double] = [], run: [Double] = []
        var cutIndex = 0
        for time in times {
            var crossesBoundary = false
            while cutIndex < cuts.count, cuts[cutIndex] <= time {
                if let previous = run.last, cuts[cutIndex] > previous { crossesBoundary = true }
                cutIndex += 1
            }
            if crossesBoundary {
                if run.count > best.count { best = run }
                run = []
            }
            run.append(time)
        }
        if run.count > best.count { best = run }
        guard let first = best.first, let last = best.last else { return nil }
        let limit = max(1, Int((duration * 1000).rounded()))
        let start = min(limit-1, max(0, Int((first * 1000).rounded())-150))
        return .init(count: best.count, startMS: start, endMS: min(limit, max(start+1, Int((last * 1000).rounded())+150)))
    }
}

nonisolated struct LeaderboardAttempt: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case uploading, pending, approved, rejected, withdrawn
        var label: String {
            switch self {
            case .uploading: "Upload unfinished"
            case .pending: "In review"
            case .approved: "Reviewed"
            case .rejected: "Not qualified"
            case .withdrawn: "Withdrawn"
            }
        }
    }
    let id: UUID
    let userID: UUID
    let sessionID: UUID
    let status: Status
    let proposedCount: Int
    let proposedStartMS: Int
    let proposedEndMS: Int
    let durationMS: Int
    let videoBytes: Int64
    let videoSHA256: String
    let objectPath: String
    let createdAt: Date
    let submittedAt: Date?
    let reviewedCount: Int?
    let reviewedStartMS: Int?
    let reviewedEndMS: Int?
    let reviewedAt: Date?
    let reviewReason: String?
    let reasonTimeMS: Int?
    let appealAt: Date?
    let videoDeletedAt: Date?
    let videoDeleteRequestedAt: Date?
    var touchReview: LeaderboardTouchReview? = nil
    var hasPendingAppeal: Bool { appealAt.map { $0 > (reviewedAt ?? .distantPast) } ?? false }
    var hasPrivateVideo: Bool { ![.uploading, .withdrawn].contains(status) && videoDeletedAt == nil && videoDeleteRequestedAt == nil }
    var proposal: RankedStreakProposal { .init(count: proposedCount, startMS: proposedStartMS, endMS: proposedEndMS) }
    enum CodingKeys: String, CodingKey {
        case id, status, userID = "user_id", sessionID = "session_id"
        case proposedCount = "proposed_count", proposedStartMS = "proposed_start_ms", proposedEndMS = "proposed_end_ms"
        case durationMS = "duration_ms", videoBytes = "video_bytes", videoSHA256 = "video_sha256", objectPath = "object_path"
        case createdAt = "created_at", submittedAt = "submitted_at", reviewedCount = "reviewed_count"
        case reviewedStartMS = "reviewed_start_ms", reviewedEndMS = "reviewed_end_ms", reviewReason = "review_reason"
        case reasonTimeMS = "reason_time_ms", appealAt = "appeal_at", videoDeletedAt = "video_deleted_at"
        case reviewedAt = "reviewed_at", videoDeleteRequestedAt = "video_delete_requested_at"
        case touchReview = "touch_review"
    }
}

nonisolated enum LeaderboardFailure: LocalizedError {
    case unavailable, signIn, originalRequired, invalidSegment, tooLarge, changedVideo, upload, limit, expired, conflict, clips
    var errorDescription: String? {
        switch self {
        case .unavailable: "The reviewed leaderboard is unavailable. Please try again later."
        case .signIn: "Sign in to send touches from a session recorded on your account."
        case .originalRequired: "Choose an original in-app recording saved on this phone. Imports and guest recordings stay in your personal history."
        case .invalidSegment: "Enter the continuous streak’s touch count and a valid start/end time within the recording."
        case .tooLarge: "These clips are larger than the current 50 MB upload limit. Choose fewer touches. Your recording remains saved on this phone."
        case .changedVideo: "The original recording has changed. This upload cannot continue."
        case .upload: "Upload paused. Keep the original on this phone and try again to resume."
        case .limit: "The beta allows three checks per day and three waiting for review. Please try again later."
        case .expired: "This upload expired. Withdraw the check and send it again."
        case .clips: "The clips for this check couldn’t be made from your recording. Your recording remains saved on this phone."
        case .conflict: "This session already has a touch check. Open Touch checks to see its status."
        }
    }
}
