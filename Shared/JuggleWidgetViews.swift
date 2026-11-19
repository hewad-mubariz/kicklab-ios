import AppIntents
import SwiftUI
import WidgetKit

/// Moves the widget's carousel on by one card. The widget reloads itself afterwards.
nonisolated struct NextJuggleCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Next card"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        JuggleWidgetData.cardOffset += 1
        return .result()
    }
}

/// The widget's look, shared so the app can draw the same cards for design review.
nonisolated enum JuggleWidgetStyle {
    static let lime = Color(red: 0xD0 / 255, green: 0xF8 / 255, blue: 0x52 / 255)
    static let ink = Color(red: 0x1A / 255, green: 0x24 / 255, blue: 0x10 / 255)

    static func display(_ size: CGFloat) -> Font { .custom("DINCondensed-Bold", size: size, relativeTo: .title) }
}

/// The night-pitch ground behind the Home Screen sizes.
struct JuggleWidgetBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.17, blue: 0.11), Color(red: 0.02, green: 0.04, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [JuggleWidgetStyle.lime.opacity(0.24), .clear], center: UnitPoint(x: 0.85, y: 0.1),
                           startRadius: 0, endRadius: 110)
        }
    }
}

/// One carousel card at one widget size.
struct JuggleWidgetContent: View {
    let family: WidgetFamily
    let data: JuggleWidgetData
    let card: JuggleWidgetCard
    let cards: [JuggleWidgetCard]

    private let lime = JuggleWidgetStyle.lime

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            Spacer(minLength: 4)
            cardBody.id(card).transition(.push(from: .trailing))
            Spacer(minLength: 8)
            startPill
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                topRow
                Spacer(minLength: 4)
                cardBody.id(card).transition(.push(from: .trailing))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "soccerball")
                    .font(.system(size: 30, weight: .semibold))
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text("Juggle")
                    .font(JuggleWidgetStyle.display(32))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .foregroundStyle(JuggleWidgetStyle.ink)
            .padding(12)
            .frame(width: 118)
            .frame(maxHeight: .infinity, alignment: .leading)
            .background(lime, in: .rect(cornerRadius: 18, style: .continuous))
        }
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .heavy)).tracking(0.8)
                .foregroundStyle(lime)
                .lineLimit(1).minimumScaleFactor(0.7)
                .widgetAccentable()
            Spacer(minLength: 4)
            // The dots and › flip to the next card; the rest of the widget opens the camera.
            Button(intent: NextJuggleCardIntent()) {
                HStack(spacing: 3) {
                    ForEach(cards, id: \.self) { item in dot(current: item == card) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.leading, 2)
                }
                .padding(.vertical, 6).padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Next card"))
        }
    }

    private func dot(current: Bool) -> some View {
        let size: CGFloat = current ? 5 : 4
        let colour: Color = current ? lime : Color.white.opacity(0.35)
        return Circle().fill(colour).frame(width: size, height: size)
    }

    private var startPill: some View {
        Text("Juggle")
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(JuggleWidgetStyle.ink)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(lime, in: .capsule)
    }

    private var label: LocalizedStringKey {
        switch card {
        case .best: "BEST STREAK"
        case .week: "THIS WEEK"
        case .run: "DAYS IN A ROW"
        case .rank: "LEADERBOARD"
        case .goal: "NEXT GOAL"
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        switch card {
        case .best:
            if data.best > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    bigNumber(data.best.formatted())
                    detail(Text("touches"))
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your first streak")
                        .font(JuggleWidgetStyle.display(26)).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.7)
                    detail(Text("starts with one session"))
                }
            }
        case .week:
            VStack(alignment: .leading, spacing: 5) {
                weekBars
                detail(Text("\(data.weekSessions) sessions"))
            }
        case .run:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(lime)
                    bigNumber(data.daysInARow.formatted())
                }
                detail(Text("Keep it going"))
            }
        case .rank:
            VStack(alignment: .leading, spacing: 0) {
                bigNumber("#" + (data.weekRank ?? data.allTimeRank ?? 0).formatted())
                detail(data.weekRank != nil ? Text("This week") : Text("All time"))
            }
        case .goal:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    bigNumber(data.nextGoal.formatted())
                    detail(Text("touches"))
                }
                progress
                detail(data.best > 0 ? Text("\(max(0, data.nextGoal - data.best)) to go") : Text("Your first goal"))
            }
        }
    }

    private func bigNumber(_ value: String) -> some View {
        Text(value)
            .font(JuggleWidgetStyle.display(46))
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.bottom, -6)
    }

    private func detail(_ text: Text) -> some View {
        text.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
    }

    private var weekBars: some View {
        let top = max(1, data.week.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(data.week.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(value > 0 ? lime.opacity(index == data.today ? 1 : 0.6) : Color.white.opacity(0.18))
                        .frame(width: 9, height: value > 0 ? 8 + 30 * CGFloat(value) / CGFloat(top) : 3)
                    Text(index < data.weekLetters.count ? data.weekLetters[index] : "")
                        .font(.system(size: 8, weight: index == data.today ? .heavy : .medium))
                        .foregroundStyle(index == data.today ? lime : .white.opacity(0.5))
                }
            }
        }
        .frame(height: 50, alignment: .bottom)
    }

    private var progress: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(lime)
                    .frame(width: max(6, geometry.size.width * min(1, CGFloat(data.best) / CGFloat(max(1, data.nextGoal)))))
            }
        }
        .frame(height: 6)
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "soccerball").font(.system(size: 11, weight: .semibold))
                Text(data.best > 0 ? data.best.formatted() : "–")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            .padding(4)
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: card == .run ? "flame.fill" : "soccerball").font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Group {
                    switch card {
                    case .best: Text("\(data.best) touches")
                    case .week: Text("\(data.weekSessions) sessions")
                    case .run: Text("\(data.daysInARow) days in a row")
                    case .rank: Text(verbatim: "#" + (data.weekRank ?? data.allTimeRank ?? 0).formatted())
                    case .goal: Text("\(data.nextGoal) touches")
                    }
                }
                .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
    }
}
