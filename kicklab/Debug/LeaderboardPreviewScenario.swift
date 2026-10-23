#if DEBUG
import Foundation

/// Fictional, in-memory boards. Never write these to accounts, history or the
/// review service. The setting and its controls are absent from Release builds.
enum LeaderboardPreviewScenario: String, CaseIterable, Identifiable {
    case live, mixed, first, podium, nearby, unranked, single, empty

    /// Set only for one launch, by `--leaderboard-preview <scenario>`.
    static let defaultsKey = "kicklab.leaderboard.previewScenario"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: "Live rankings"
        case .mixed: "Mixed players"
        case .first: "You lead"
        case .podium: "You on the podium"
        case .nearby: "Nearby ranks & tied scores"
        case .unranked: "You are not ranked"
        case .single: "Only one player"
        case .empty: "Empty board"
        }
    }

    func board(period: LeaderboardPeriod) -> LeaderboardBoard {
        guard self != .live, self != .empty else { return .init(entries: [], around: []) }
        if self == .single {
            return .init(entries: [entry(rank: 1, name: "Alex", touches: period == .week ? 24 : 78,
                                        you: true, country: "DE", duration: period == .week ? 22 : 61)], around: [])
        }
        // Includes short, long and non-Latin names, an exact score tie, and
        // independent missing country, duration, spin and height measurements.
        let names = ["Amara", "Mateo Silva", "Yuki", "Rafael", "Noor Al-Hassan",
                     "João", "Sofia Alexandrou", "민준", "Inès", "Omar", "Luca", "Zara"]
        let countries: [String?] = ["NG", "BR", "JP", "DE", "MA", "PT", "GR", "KR", "FR", nil, "IT", "GB"]
        let scores = period == .week
            ? [842, 736, 615, 458, 458, 392, 287, 164, 92, 48, 21, 7]
            : [12480, 8276, 5402, 3180, 3180, 2406, 1950, 1284, 861, 420, 180, 64]
        let spins: [Int?] = [126, 84, 168, 96, nil, 42, 110, nil, 0, 72, nil, nil]
        let heights: [LeaderboardJugglingHeight?] = [.normal, .low, .high, .mixed, .low, nil,
                                                    .normal, .high, .low, .mixed, nil, nil]
        let yourRank: Int? = switch self {
        case .first: 1
        case .podium: 3
        case .mixed: 4
        default: nil
        }
        let entries = names.indices.map { index in
            entry(rank: index + 1, name: index + 1 == yourRank ? "Alex" : names[index],
                  touches: scores[index], you: index + 1 == yourRank, country: countries[index],
                  duration: index == 10 ? nil : Int(Double(scores[index]) / (index.isMultiple(of: 2) ? 1.8 : 2.2)),
                  spin: spins[index], height: heights[index])
        }
        guard self == .nearby else { return .init(entries: entries, around: []) }
        let rank = period == .week ? 48 : 128
        let score = period == .week ? 18 : 96
        return .init(entries: entries.prefix(10).map { $0 }, around: [
            entry(rank: rank - 1, name: "Aisha", touches: score, country: "KE", duration: score, spin: 64, height: .low),
            entry(rank: rank, name: "Alex", touches: score, you: true, country: "DE", duration: score + 1, spin: 92, height: .normal),
            entry(rank: rank + 1, name: "Ben", touches: score - 1, country: nil, duration: nil)
        ])
    }

    private func entry(rank: Int, name: String, touches: Int, you: Bool = false,
                       country: String?, duration: Int?, spin: Int? = nil,
                       height: LeaderboardJugglingHeight? = nil) -> LeaderboardEntry {
        .init(rank: rank, name: name, touches: touches, isYou: you,
              streakDurationMS: duration.map { max(1, $0) * 1000 }, countryCode: country,
              backspinRPM: spin, typicalHeight: height, isPreview: true)
    }
}
#endif
