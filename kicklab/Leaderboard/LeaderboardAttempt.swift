import Foundation

nonisolated enum LeaderboardRules {
    static let version = "beta-1"
    static let maximumVideoBytes: Int64 = 2_147_483_648
    static let privacy = "Your original video is private to you and the review team. It is not used for model training or shown to other players. Pending and rejected videos expire 30 days after submission or the latest review or appeal; approved videos are kept until you withdraw the attempt or delete your account. Withdrawal hides the score immediately and queues video deletion within 24 hours."
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

    /// Conservative suggestion only. A reviewer can join segments when the original
    /// video proves continuity or restore contacts missed by the device.
    static func suggest(touchTimes: [Double], boundaries: [Double], duration: Double) -> Self? {
        guard duration.isFinite, duration > 0, duration <= 86_400 else { return nil }
        let times = Array(Set(touchTimes.filter { $0.isFinite && $0 >= 0 && $0 <= duration })).sorted()
        let cuts = boundaries.filter { $0.isFinite && $0 >= 0 && $0 <= duration }.sorted()
        var best: [Double] = [], run: [Double] = []
        for time in times {
            if let previous = run.last, time-previous > 2 || cuts.contains(where: { $0 > previous && $0 <= time }) {
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
    }
}

nonisolated enum LeaderboardFailure: LocalizedError {
    case unavailable, signIn, originalRequired, invalidSegment, tooLarge, changedVideo, upload, limit, expired, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: "The reviewed leaderboard is unavailable. Please try again later."
        case .signIn: "Sign in to submit an attempt recorded on your account."
        case .originalRequired: "Choose an original in-app recording saved on this phone. Imports and guest recordings stay in your personal history."
        case .invalidSegment: "Enter the continuous streak’s touch count and a valid start/end time within the recording."
        case .tooLarge: "This original is larger than the beta’s 2 GB upload limit. Record a shorter attempt."
        case .changedVideo: "The original recording has changed. This upload cannot continue."
        case .upload: "Upload paused. Keep the original on this phone and try again to resume."
        case .limit: "The beta allows three submissions per day and three awaiting review. Please try again later."
        case .expired: "This upload expired. Withdraw it and record a new attempt."
        case .conflict: "This attempt already has a submission. Open My submissions to see its status."
        }
    }
}
