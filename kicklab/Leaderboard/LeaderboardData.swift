import Foundation

/// One ranked player. The beta ranks the device's best continuous streak.
struct LeaderboardEntry: Identifiable, Equatable {
    let rank: Int
    let name: String
    let touches: Int
    var isYou = false
    /// The player's picture once scores come from accounts; without one a placeholder shows.
    var photo: URL? = nil
    /// Set when a confirmed touch check scores this entry.
    var attemptID: UUID? = nil
    /// Old responses can still contain a review ID. Review presentation must also
    /// respect the beta switch, including cached entries and accessibility labels.
    var hasConfirmedTouchCheck: Bool { LeaderboardRules.touchChecks && attemptID != nil }
    /// The session that ranks, on your own entry only.
    var sessionID: UUID? = nil
    var streakDurationMS: Int? = nil
    var countryCode: String? = nil
    /// Reserved for later style measurements. Beta cards use the saved streak
    /// duration and rhythm; real results keep these optional fields nil.
    var backspinRPM: Int? = nil
    var typicalHeight: LeaderboardJugglingHeight? = nil
    var isPreview = false
    var backspinLabel: String { backspinRPM.map { "\($0) rpm" } ?? String(localized: "Unavailable") }
    var heightLabel: String { typicalHeight?.rawValue ?? String(localized: "Unavailable") }
    var streakDurationLabel: String {
        guard let duration = streakDurationMS, duration > 0 else { return String(localized: "Unavailable") }
        if duration < 1000 { return "<1s" }
        return String(format: "%d:%02d", duration / 60000, duration / 1000 % 60)
    }
    /// Counted touches per minute over the saved streak, without another video pass.
    /// One contact alone cannot describe a juggling rhythm.
    var averageRhythmPerMinute: Int? {
        guard touches > 1, let duration = streakDurationMS, duration > 0 else { return nil }
        return Int((Double(touches) * 60000 / Double(duration)).rounded())
    }
    var averageRhythmLabel: String {
        averageRhythmPerMinute.map { String(localized: "\($0.formatted()) touches/min") } ?? String(localized: "Unavailable")
    }
    var id: Int { rank }
}

enum LeaderboardJugglingHeight: String, CaseIterable {
    case low = "Low", normal = "Normal", high = "High", mixed = "Mixed"
}

enum LeaderboardPeriod: String, CaseIterable, Identifiable {
    case week = "This week", allTime = "All time"
    var id: String { rawValue }
    /// The raw value keys cached boards; this is what the switch shows.
    var title: String {
        switch self {
        case .week: String(localized: "This week")
        case .allTime: String(localized: "All time")
        }
    }
}

struct LeaderboardSelection: Equatable {
    var period = LeaderboardPeriod.week
}

#if DEBUG
/// Local preview data only. These entries are never submitted to the live leaderboard.
enum LeaderboardSample {
    /// `yourName` only feeds your placeholder initials; your rows still read "You".
    static func board(_ selection: LeaderboardSelection, personalBest: Int, yourName: String) -> [LeaderboardEntry] {
        var players: [(name: String, touches: Int, isYou: Bool)] = roster(selection)
            .prefix(personalBest > 0 ? 9 : 10).map { ($0.0, $0.1, false) }
        if personalBest > 0 { players.append((yourName, personalBest, true)) }
        players.sort { $0.touches > $1.touches }
        var entries: [LeaderboardEntry] = []
        for (index, player) in players.enumerated() {
            entries.append(LeaderboardEntry(rank: index + 1, name: player.name, touches: player.touches,
                                            isYou: player.isYou, streakDurationMS: player.touches * 500, isPreview: true))
        }
        return entries
    }

    private static func roster(_ selection: LeaderboardSelection) -> [(String, Int)] {
        let leaders: [(String, Int)]
        let names: [String]
        switch selection.period {
        case .week:
            leaders = [("Leo", 458), ("Noah", 421), ("Amir", 396),
                       ("Kai", 342), ("Luca", 315)]
            names = ["Mateo", "Yuki", "Sami", "Elias", "Omar"]
        case .allTime:
            leaders = [("Amir", 1284), ("Leo", 1102), ("Noah", 978),
                       ("Yuki", 861), ("Kai", 790)]
            names = ["Luca", "Mateo", "Ines", "Sami", "Omar"]

        }
        let floor = leaders.last?.1 ?? 300
        let step = selection.period == .week ? 6 : 19
        var players = leaders
        for (index, name) in names.enumerated() {
            players.append((name, floor - (index + 1) * step - index % 3))
        }
        return players
    }
}

/// Exercises rankings arriving after the screen mounts, without a live account
/// or database writes. Each request changes the score so UI checks can distinguish
/// a cached tab from a fresh pull-to-refresh response.
enum LeaderboardReview {
    private static var requests: [LeaderboardPeriod: Int] = [:]
    static var count: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--leaderboard-review-count"), args.indices.contains(index + 1) else { return nil }
        return Int(args[index + 1]).map { max(0, min(10, $0)) }
    }

    static func board(count: Int, period: LeaderboardPeriod) async throws -> (entries: [LeaderboardEntry], around: [LeaderboardEntry]) {
        requests[period, default: 0] += 1
        let revision = requests[period, default: 1] - 1
        try await Task.sleep(for: .milliseconds(700))
        if count == 1 {
            // Exercise a legacy server response through the real detail rendering.
            // This launch-only fixture never fetches or writes account data.
            let legacyReview = ProcessInfo.processInfo.arguments.contains("--leaderboard-legacy-review")
            return ([LeaderboardEntry(rank: 1, name: "Alex", touches: (period == .week ? 74 : 96) + revision,
                                      isYou: !legacyReview,
                                      attemptID: legacyReview ? UUID(uuidString: "00000000-0000-0000-0000-000000000001") : nil)], [])
        }
        let entries = LeaderboardSample.board(.init(period: period), personalBest: 0, yourName: "")
        return (Array(entries.prefix(count)), [])
    }
}
#endif
