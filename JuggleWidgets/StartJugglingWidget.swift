import SwiftUI
import WidgetKit

/// The Home Screen and Lock Screen widget: a carousel of your best streak, this week,
/// days in a row, your leaderboard place and your next goal. It moves on by itself
/// every few minutes; the › button moves it at once. Anywhere else opens the camera.
struct StartJugglingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.juggledude.start-juggling", provider: Provider()) { entry in
            StartJugglingWidgetView(entry: entry)
        }
        .configurationDisplayName("Start juggling")
        .description("Your best streak, this week and your next goal. Tap to start juggling.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }

    struct Entry: TimelineEntry {
        let date: Date
        let data: JuggleWidgetData
        let card: JuggleWidgetCard
        let cards: [JuggleWidgetCard]
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            var sample = JuggleWidgetData()
            sample.best = 42
            sample.nextGoal = 50
            return Entry(date: .now, data: sample, card: .best, cards: JuggleWidgetCard.cards(for: sample))
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(context.isPreview && JuggleWidgetData.load().best == 0 ? placeholder(in: context) : entry(at: .now))
        }

        /// Two hours of cards, one per slot; then WidgetKit asks again.
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            let now = Date.now
            let interval = JuggleWidgetCard.interval
            let nextSlot = (now.timeIntervalSince1970 / interval).rounded(.down) * interval + interval
            let dates = [now] + (0..<24).map { Date(timeIntervalSince1970: nextSlot + Double($0) * interval) }
            completion(Timeline(entries: dates.map(entry(at:)), policy: .atEnd))
        }

        private func entry(at date: Date) -> Entry {
            let data = JuggleWidgetData.load()
            let cards = JuggleWidgetCard.cards(for: data)
            return Entry(date: date, data: data,
                         card: JuggleWidgetCard.card(at: date, in: cards, offset: JuggleWidgetData.cardOffset),
                         cards: cards)
        }
    }
}

private struct StartJugglingWidgetView: View {
    let entry: StartJugglingWidget.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        JuggleWidgetContent(family: family, data: entry.data, card: entry.card, cards: entry.cards)
            .widgetURL(URL(string: "juggledude://start-juggling"))
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium {
                    JuggleWidgetBackground()
                } else {
                    Color.clear
                }
            }
    }
}
