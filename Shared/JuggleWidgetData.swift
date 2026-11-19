import Foundation
import WidgetKit

/// What the Juggle Dude widget shows. The app writes it to the shared App Group when
/// the history, the best streak or a leaderboard place changes; the widget only reads
/// it. Missing data is fine: the widget then shows a first-session carousel.
nonisolated struct JuggleWidgetData: Codable, Equatable, Sendable {
    var best = 0
    /// The best session of each day this week, in the week's own order.
    var week: [Int] = Array(repeating: 0, count: 7)
    var weekLetters: [String] = ["M", "T", "W", "T", "F", "S", "S"]
    var today = 0
    var weekSessions = 0
    var daysInARow = 0
    var nextGoal = 10
    var weekRank: Int?
    var allTimeRank: Int?

    static let appGroup = "group.com.juggledude"
    private static let dataKey = "juggle.widget.data"
    private static let cardKey = "juggle.widget.card-offset"
    private static var store: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> JuggleWidgetData {
        guard let stored = store?.data(forKey: dataKey),
              let data = try? JSONDecoder().decode(JuggleWidgetData.self, from: stored) else { return JuggleWidgetData() }
        return data
    }

    /// Changes the stored data and refreshes the widget, only when something changed.
    static func update(_ change: (inout JuggleWidgetData) -> Void) {
        var data = load()
        let before = data
        change(&data)
        guard data != before, let encoded = try? JSONEncoder().encode(data) else { return }
        store?.set(encoded, forKey: dataKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// How far the › button has moved the carousel on.
    static var cardOffset: Int {
        get { store?.integer(forKey: cardKey) ?? 0 }
        set { store?.set(newValue, forKey: cardKey) }
    }
}

/// The carousel's cards, in order. Days in a row and the leaderboard place only
/// appear when there is one to show.
nonisolated enum JuggleWidgetCard: String, CaseIterable, Codable, Sendable {
    case best, week, run, rank, goal

    static func cards(for data: JuggleWidgetData) -> [JuggleWidgetCard] {
        var cards: [JuggleWidgetCard] = [.best, .week]
        if data.daysInARow >= 2 { cards.append(.run) }
        if data.weekRank != nil || data.allTimeRank != nil { cards.append(.rank) }
        cards.append(.goal)
        return cards
    }

    /// Seconds each card stays before the widget moves on by itself.
    static let interval: TimeInterval = 300

    /// The card showing at `date`: the clock turns the carousel, the › button adds one.
    static func card(at date: Date, in cards: [JuggleWidgetCard], offset: Int) -> JuggleWidgetCard {
        let slot = Int(date.timeIntervalSince1970 / interval)
        return cards[((slot + offset) % cards.count + cards.count) % cards.count]
    }
}
