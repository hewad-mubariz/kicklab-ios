import Foundation

/// One ranked player. `touches` is their best single juggling session in the period.
struct LeaderboardEntry: Identifiable, Equatable {
    let rank: Int
    let name: String
    let touches: Int
    var isYou = false
    /// The player's picture once scores come from accounts; without one a placeholder shows.
    var photo: URL? = nil
    var id: Int { rank }
}

enum LeaderboardPeriod: String, CaseIterable, Identifiable {
    case week = "This week", allTime = "All time"
    var id: String { rawValue }
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
            entries.append(LeaderboardEntry(rank: index + 1, name: player.name, touches: player.touches, isYou: player.isYou))
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
            return ([LeaderboardEntry(rank: 1, name: "Alex", touches: (period == .week ? 74 : 96) + revision, isYou: true)], [])
        }
        let entries = LeaderboardSample.board(.init(period: period), personalBest: 0, yourName: "")
        return (Array(entries.prefix(count)), [])
    }
}
#endif
