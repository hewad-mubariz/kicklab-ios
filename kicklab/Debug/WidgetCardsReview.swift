#if DEBUG
import SwiftUI
import WidgetKit

/// Design review: every widget card at Home Screen and Lock Screen sizes, drawn in the
/// app with sample numbers, so they can be checked without adding the widget.
struct WidgetCardsReview: View {
    private static let sample: JuggleWidgetData = {
        var data = JuggleWidgetData()
        data.best = 42
        data.week = [0, 42, 64, 128, 0, 0, 0]
        data.today = 3
        data.weekSessions = 3
        data.daysInARow = 3
        data.nextGoal = 50
        data.weekRank = 23
        return data
    }()

    var body: some View {
        let data = Self.sample
        let cards = JuggleWidgetCard.cards(for: data)
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.fixed(170), spacing: 14), GridItem(.fixed(170))], spacing: 14) {
                    ForEach(cards, id: \.self) { card in
                        tile(.systemSmall, data: data, card: card, cards: cards).frame(width: 170, height: 170)
                    }
                    tile(.systemSmall, data: JuggleWidgetData(), card: .best,
                         cards: JuggleWidgetCard.cards(for: JuggleWidgetData())).frame(width: 170, height: 170)
                }
                tile(.systemMedium, data: data, card: .week, cards: cards).frame(width: 354, height: 170)
                HStack(spacing: 14) {
                    JuggleWidgetContent(family: .accessoryCircular, data: data, card: .best, cards: cards)
                        .frame(width: 72, height: 72)
                    JuggleWidgetContent(family: .accessoryRectangular, data: data, card: .run, cards: cards)
                        .frame(width: 170, height: 72)
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.35), in: .rect(cornerRadius: 20))
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.5)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .accessibilityIdentifier("widget-review")
    }

    private func tile(_ family: WidgetFamily, data: JuggleWidgetData, card: JuggleWidgetCard,
                      cards: [JuggleWidgetCard]) -> some View {
        JuggleWidgetContent(family: family, data: data, card: card, cards: cards)
            .padding(16)
            .background(JuggleWidgetBackground())
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }
}
#endif
