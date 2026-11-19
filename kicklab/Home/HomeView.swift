import SwiftUI
import UIKit

/// Home: one dark stage with the player's best and the camera, then the next goal,
/// this week's sessions and the other modes. Only real numbers are shown.
struct HomeView: View {
    let personalBest: Int
    let onJuggling: () -> Void
    let onPowerShot: () -> Void
    let onImport: () -> Void
    let onProfile: () -> Void
    let onSetupGuide: () -> Void
    var onLeaderboard: (() -> Void)? = nil
    var onLeaderboardRules: (() -> Void)? = nil
    var onHistory: (() -> Void)? = nil
    /// Lets the leaderboard zoom out of its button.
    var leaderboardZoom: Namespace.ID? = nil
    var profileZoom: Namespace.ID? = nil
    var showsDestinationShortcuts = true
    /// Newest first, as history keeps them. Drives the last-session line and the week.
    var sessions: [HistorySession] = []
    var playerName: String? = nil
    /// Opens the camera with a goal label. Nil hides the goal's start action.
    var onGoal: ((Int) -> Void)? = nil
    var profilePhoto = HomeProfilePhoto()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var photo: UIImage?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                stage
                HomeGoalCard(best: personalBest, revealed: revealed, onStart: onGoal)
                HomeWeekCard(sessions: sessions, revealed: revealed, onOpen: onHistory)
                ballDistanceCard
                if let onHistory { historyRow(onHistory) }
                Button(action: onSetupGuide) {
                    Label("How to set up your camera", systemImage: "viewfinder")
                        .font(.footnote)
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-setup-guide")
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.background(scheme).ignoresSafeArea())
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .accessibilityIdentifier("home-screen")
        .onAppear { revealed = true }
        .task(id: profilePhoto) { photo = profilePhoto.load() }
        // Keeps the Home Screen widget's carousel in step with Home.
        .onChange(of: widgetFields, initial: true) { _, fields in
            #if DEBUG
            // Test runs use sample history; never show it on the real widget.
            if SessionHistoryReview.requested { return }
            #endif
            JuggleWidgetData.update { data in
                data.best = fields.best
                data.week = fields.week
                data.weekLetters = fields.letters
                data.today = fields.today
                data.weekSessions = fields.sessions
                data.daysInARow = fields.daysInARow
                data.nextGoal = fields.nextGoal
            }
        }
    }

    private struct WidgetFields: Equatable {
        var best: Int, week: [Int], letters: [String], today: Int, sessions: Int, daysInARow: Int, nextGoal: Int
    }

    private var widgetFields: WidgetFields {
        let week = HomeWeek(sessions: sessions)
        return WidgetFields(best: personalBest, week: week.days.map(\.best), letters: week.days.map(\.letter),
                            today: week.days.firstIndex(where: \.isToday) ?? 0, sessions: week.sessionCount,
                            daysInARow: daysInARow, nextGoal: HomeGoals.next(after: personalBest))
    }

    // MARK: Header

    /// "Hey" with the player's first name, a short line that nudges the next session,
    /// and their photo, which opens Profile.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                greeting
                    .font(TrainingHomeStyle.display(36, relativeTo: .largeTitle))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-greeting")
                nudge
                    .font(.subheadline)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("home-subtitle")
            }
            Spacer(minLength: 0)
            if showsDestinationShortcuts, let onLeaderboard {
                HomeLeaderboardButton(action: onLeaderboard, zoom: leaderboardZoom)
            }
            HomeProfileButton(action: onProfile, zoom: profileZoom, photo: photo)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    // MARK: Stage

    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The left column: the day run, the best streak just under it, and the last
            // session at the bottom. The ball juggles on the right; this area keeps at
            // least its fixed height, because the ball's ground line depends on it.
            VStack(alignment: .leading, spacing: 0) {
                if daysInARow >= 2 { dayRun.padding(.bottom, 14) }
                record
                Spacer(minLength: 10)
                // An empty take (nothing counted) isn't worth showing as the last session.
                if let last = sessions.first(where: { $0.touches > 0 }) { lastSessionLine(last) }
            }
            .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 206, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 0 : 188, alignment: .topLeading)
            startButton.padding(.top, 18)
            importButton.padding(.top, 10)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { stageBackdrop }
        .clipShape(.rect(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(scheme == .dark ? 0.08 : 0))
        }
        .environment(\.colorScheme, .dark)
    }

    /// Consecutive days with a session, counting from today, or from yesterday
    /// so the run still shows before today's session.
    private var daysInARow: Int {
        let calendar = Calendar.current
        let days = Set(sessions.map { calendar.startOfDay(for: $0.completedAt) })
        var day = calendar.startOfDay(for: .now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var count = 0
        while days.contains(day), let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            count += 1; day = previous
        }
        return count
    }

    private var dayRun: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill").foregroundStyle(TrainingHomeStyle.lime)
            Text("\(daysInARow) days in a row")
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(.black.opacity(0.35), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-days-in-a-row")
    }

    /// A night pitch with no player: two floodlights, and a ball that juggles itself
    /// with a lime Glow Trail.
    private var stageBackdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.15, blue: 0.10), TrainingHomeStyle.cardBlack],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.06, y: -0.03), startRadius: 0, endRadius: 240)
            RadialGradient(colors: [.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.97, y: -0.01), startRadius: 0, endRadius: 210)
            RadialGradient(colors: [TrainingHomeStyle.lime.opacity(0.15), .clear],
                           center: UnitPoint(x: 0.72, y: 0.28), startRadius: 0, endRadius: 190)
            if !typeSize.isAccessibilitySize { HomeJugglingMotion(animates: !reduceMotion) }
            LinearGradient(stops: [.init(color: .clear, location: 0.52),
                                   .init(color: TrainingHomeStyle.cardBlack.opacity(0.8), location: 0.66),
                                   .init(color: TrainingHomeStyle.cardBlack, location: 0.95)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [TrainingHomeStyle.lime.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.1, y: 0.45), startRadius: 0, endRadius: 230)
        }
        .accessibilityHidden(true)
    }

    private var greeting: Text {
        guard let name = playerName?.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            return Text("Hey there")
        }
        return Text("Hey, \(name)")
    }

    private var nudge: Text {
        if personalBest <= 0 { return Text("Ready for your first session?") }
        if sessions.contains(where: { $0.touches > 0 && Calendar.current.isDateInToday($0.completedAt) }) {
            return Text("Nice session today. Go again?")
        }
        return Text("Ready to beat \(personalBest)?")
    }

    private var record: some View {
        VStack(alignment: .leading, spacing: 0) {
            if personalBest > 0 {
                Text("BEST STREAK")
                    .font(.caption.weight(.bold)).tracking(1.6)
                    .foregroundStyle(TrainingHomeStyle.lime)
                    .padding(.bottom, 6)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(revealed ? personalBest : 0, format: .number)
                        .font(TrainingHomeStyle.display(96, relativeTo: .largeTitle))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(revealed ? personalBest : 0)))
                        .animation(reduceMotion ? nil : .smooth(duration: 1.1).delay(0.2), value: revealed)
                        .animation(.smooth(duration: 0.8), value: personalBest)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.top, 4)
                        .padding(.bottom, -12)
                    Text("touches")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.72))
                }
            } else {
                Text("Your first session starts here.")
                    .font(TrainingHomeStyle.display(38, relativeTo: .largeTitle))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(personalBest > 0 ? "Personal best streak, \(personalBest) consecutive touches" : "Personal best streak. Record your first juggling streak.")
        .accessibilityIdentifier("home-personal-best")
    }

    /// The touches on one line and when on the next, so the line never breaks mid-phrase.
    private func lastSessionLine(_ last: HistorySession) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Last session: \(last.touches) touches")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
            Text(last.completedAt, format: Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide,
                                                                    locale: AppLanguage.locale,
                                                                    capitalizationContext: .beginningOfSentence))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-last-session")
    }

    private var startButton: some View {
        Button(action: onJuggling) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill").font(.system(size: 17, weight: .semibold))
                Text("Start juggling").font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(TrainingHomeStyle.buttonInk)
            .background(TrainingHomeStyle.lime, in: .rect(cornerRadius: 18, style: .continuous))
            .shadow(color: TrainingHomeStyle.lime.opacity(0.3), radius: 18, y: 6)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityIdentifier("module-juggling")
    }

    private var importButton: some View {
        Button(action: onImport) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 15, weight: .semibold))
                Text("Import a juggling video").font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(.white.opacity(0.09), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16)))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityIdentifier("home-import-video")
    }

    // MARK: Lower modules

    private var ballDistanceCard: some View {
        Button(action: onPowerShot) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BALL DISTANCE")
                        .font(TrainingHomeStyle.display(28, relativeTo: .title2))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("Record your shot.\nMake it yours with effects.")
                        .font(.caption).lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.74))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TrainingHomeStyle.lime)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
            .background {
                ZStack {
                    TrainingHomeStyle.cardBlack
                    Color.clear.overlay {
                        // Lower the ball so the corner arrow sits in the sky.
                        Image("home-power-shot").resizable().scaledToFill().offset(y: 16)
                    }
                    .clipped()
                    LinearGradient(stops: [.init(color: TrainingHomeStyle.cardBlack.opacity(0.94), location: 0),
                                           .init(color: TrainingHomeStyle.cardBlack.opacity(0.6), location: 0.5),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .accessibilityHidden(true)
            }
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel(Text("BALL DISTANCE"))
        .accessibilityHint(Text("Record your shot.\nMake it yours with effects."))
        .accessibilityIdentifier("module-power-shot")
    }

    private func historyRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TrainingHomeStyle.accent(scheme))
                    .frame(width: 40, height: 40)
                    .background(TrainingHomeStyle.accent(scheme).opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session history").font(.subheadline.weight(.semibold))
                    Text("Your touches, time and replays").font(.caption)
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityIdentifier("home-session-history")
    }
}

// MARK: - Goal

/// Fixed practice milestones. The next one is the first above the recorded best.
enum HomeGoals {
    static let ladder = [10, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000]

    static func next(after best: Int) -> Int {
        ladder.first { $0 > best } ?? (best / 250 + 1) * 250
    }
}

private struct HomeGoalCard: View {
    let best: Int
    let revealed: Bool
    let onStart: ((Int) -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var goal: Int { HomeGoals.next(after: best) }
    private var progress: Double { min(1, Double(max(0, best)) / Double(goal)) }

    var body: some View {
        Button { onStart?(goal) } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Next goal").textCase(.uppercase)
                            .font(.caption.weight(.bold)).tracking(1.4)
                            .foregroundStyle(TrainingHomeStyle.accent(scheme))
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(goal, format: .number)
                                .font(TrainingHomeStyle.display(48, relativeTo: .title))
                                .monospacedDigit()
                                .padding(.bottom, -6)
                            Text("touches").font(.subheadline.weight(.semibold))
                                .foregroundStyle(TrainingHomeStyle.muted(scheme))
                        }
                    }
                    Spacer(minLength: 0)
                    Group {
                        if best > 0 { Text("\(goal - best) to go") } else { Text("First goal") }
                    }
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(TrainingHomeStyle.buttonInk)
                    .background(TrainingHomeStyle.lime, in: .capsule)
                }
                GoalTrack(progress: revealed ? progress : 0,
                          ticks: HomeGoals.ladder.filter { $0 < goal }.map { Double($0) / Double(goal) })
                    .animation(reduceMotion ? nil : .spring(duration: 1.1, bounce: 0.2).delay(0.35), value: revealed)
                    .animation(.spring(duration: 0.8), value: progress)
                HStack(spacing: 8) {
                    Text(verbatim: "\(best.formatted()) / \(goal.formatted())")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    Spacer(minLength: 0)
                    if onStart != nil {
                        HStack(spacing: 6) {
                            Text("Go for \(goal)")
                            Image(systemName: "arrow.right")
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 24, style: .continuous))
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(HomePressStyle())
        .disabled(onStart == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(best > 0 ? "Next goal, \(goal) touches. \(goal - best) to go." : "Next goal, \(goal) touches.")
        .accessibilityHint(onStart == nil ? "" : "Opens the camera with this goal.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home-next-goal")
    }
}

private struct GoalTrack: View {
    let progress: Double
    let ticks: [Double]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = max(0, min(1, progress)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: scheme == .dark
                                         ? [Color(red: 0.55, green: 0.70, blue: 0.20), TrainingHomeStyle.lime]
                                         : [TrainingHomeStyle.accent(scheme), Color(red: 0.62, green: 0.78, blue: 0.22)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fill, progress > 0 ? 12 : 0))
                ForEach(ticks, id: \.self) { tick in
                    Circle()
                        .fill(tick * width <= fill ? TrainingHomeStyle.buttonInk.opacity(0.35) : TrainingHomeStyle.muted(scheme).opacity(0.45))
                        .frame(width: 4, height: 4)
                        .offset(x: tick * width - 2)
                }
                Image(systemName: "soccerball")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(.white, in: .circle)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .offset(x: max(0, min(width - 26, fill - 13)))
                    .opacity(progress > 0 ? 1 : 0)
            }
            .frame(height: 12)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}

// MARK: - Week

private struct HomeWeek {
    struct Day: Identifiable {
        let id: Int
        let symbol: String
        /// One letter, for the widget's tiny bars.
        let letter: String
        let best: Int
        let isToday: Bool
    }

    let days: [Day]
    let sessionCount: Int

    init(sessions: [HistorySession], now: Date = .now) {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        var symbols = Calendar.current
        symbols.locale = AppLanguage.locale
        let names = symbols.shortStandaloneWeekdaySymbols
        let letters = symbols.veryShortStandaloneWeekdaySymbols
        var count = 0
        days = (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let matching = sessions.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }
            count += matching.count
            let weekday = calendar.component(.weekday, from: day)
            return Day(id: offset, symbol: names[(weekday - 1) % names.count],
                       letter: letters[(weekday - 1) % letters.count],
                       best: matching.map(\.touches).max() ?? 0,
                       isToday: calendar.isDate(day, inSameDayAs: now))
        }
        sessionCount = count
    }
}

/// This week as ball markers: a bar for each day's best session, with a classic ball
/// resting in a cup on top, each turned a little differently. The week's best bar glows.
private struct HomeWeekCard: View {
    let sessions: [HistorySession]
    let revealed: Bool
    let onOpen: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var balls: [CGImage] = HomeBallArt.classicBalls ?? []
    private let barMax: CGFloat = 76
    private let ballSize: CGFloat = 24
    private let barWidth: CGFloat = 34
    /// The cup pressed into each bar's top: a little wider than the ball, so a thin
    /// dark gap shows round it, and deep enough that the bar's corners hold it.
    private let cupRadius: CGFloat = 14
    private let cupDepth: CGFloat = 9.5

    var body: some View {
        let week = HomeWeek(sessions: sessions)
        let top = max(1, week.days.map(\.best).max() ?? 1)
        Button { onOpen?() } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This week").font(.title3.weight(.bold))
                        Text("Best session · touches").font(.caption)
                            .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    }
                    Spacer(minLength: 8)
                    Text("\(week.sessionCount) sessions")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                }
                VStack(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(week.days) { day in
                            column(day, top: top)
                                .frame(maxWidth: .infinity)
                                .animation(reduceMotion ? nil : .spring(duration: 0.75, bounce: 0.3)
                                    .delay(0.4 + Double(day.id) * 0.06), value: revealed)
                        }
                    }
                    .frame(height: barMax + ballSize + 20, alignment: .bottom)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(TrainingHomeStyle.muted(scheme).opacity(0.25)).frame(height: 1)
                    }
                    HStack(spacing: 0) {
                        ForEach(week.days) { day in
                            Text(day.symbol)
                                .font(.caption.weight(day.isToday ? .bold : .medium))
                                .foregroundStyle(day.isToday ? TrainingHomeStyle.accent(scheme) : TrainingHomeStyle.muted(scheme))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 24, style: .continuous))
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(HomePressStyle())
        .disabled(onOpen == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week, \(week.sessionCount) sessions")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home-week")
        .task { if balls.isEmpty { balls = await HomeBallArt.loadClassic() } }
    }

    @ViewBuilder
    private func column(_ day: HomeWeek.Day, top: Int) -> some View {
        if day.best > 0 {
            let best = day.best == top
            let height = 20 + (barMax - 20) * CGFloat(day.best) / CGFloat(top)
            // Like the ball picker: after the bar rises, the ball drops into its cup,
            // the bar gives a little and springs back, and the cup flashes.
            KeyframeAnimator(initialValue: Landing(), trigger: reduceMotion ? false : revealed) { landing in
                let barTop = (revealed ? height : 0) * landing.squash
                let ballCentre = barTop + cupRadius - cupDepth
                ZStack(alignment: .bottom) {
                    CupBar(cupRadius: cupRadius, depth: cupDepth)
                        .fill(barFill(best: best))
                        .overlay {
                            CupBar(cupRadius: cupRadius, depth: cupDepth, rimOnly: true)
                                .stroke(.black.opacity(0.28), lineWidth: 1.5)
                                .clipShape(CupBar(cupRadius: cupRadius, depth: cupDepth))
                        }
                        .frame(width: barWidth, height: max(0.01, revealed ? height : 0))
                        .scaleEffect(x: 2 - landing.squash, y: landing.squash, anchor: .bottom)
                        .shadow(color: best ? TrainingHomeStyle.lime.opacity(scheme == .dark ? 0.45 : 0.3) : .clear, radius: 10)
                    Ellipse()
                        .fill(TrainingHomeStyle.lime)
                        .frame(width: 34, height: 9)
                        .blur(radius: 3)
                        .opacity(landing.flash)
                        .offset(y: -(barTop - cupDepth * 0.6) + 4.5)
                    marker(day)
                        .opacity(revealed ? landing.ball : 0)
                        .offset(y: -ballCentre + ballSize / 2 + landing.lift)
                    Text(day.best.formatted())
                        .font(.footnote.weight(.bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(best && scheme == .dark ? TrainingHomeStyle.lime : TrainingHomeStyle.ink(scheme))
                        .opacity(revealed ? landing.number : 0)
                        .offset(y: -(ballCentre + ballSize / 2 + 3))
                }
            } keyframes: { _ in
                let drop = 0.75 + Double(day.id) * 0.06
                KeyframeTrack(\.ball) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: drop)
                    LinearKeyframe(1, duration: 0.08)
                }
                KeyframeTrack(\.lift) {
                    MoveKeyframe(-30)
                    LinearKeyframe(-30, duration: drop)
                    CubicKeyframe(0, duration: 0.26, startVelocity: 0, endVelocity: 260)
                    CubicKeyframe(-6, duration: 0.11)
                    CubicKeyframe(0, duration: 0.11)
                }
                KeyframeTrack(\.squash) {
                    LinearKeyframe(1, duration: drop + 0.26)
                    CubicKeyframe(0.84, duration: 0.05)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                }
                KeyframeTrack(\.flash) {
                    LinearKeyframe(0, duration: drop + 0.26)
                    LinearKeyframe(0.9, duration: 0.04)
                    LinearKeyframe(0, duration: 0.4)
                }
                KeyframeTrack(\.number) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: drop + 0.3)
                    LinearKeyframe(1, duration: 0.2)
                }
            }
            .frame(height: barMax + ballSize + 24, alignment: .bottom)
        } else {
            Capsule()
                .fill(TrainingHomeStyle.muted(scheme).opacity(0.35))
                .frame(width: 16, height: 3)
                .padding(.bottom, 2)
        }
    }

    /// The resting values; every landing ends here, and Reduce Motion stays here.
    private struct Landing {
        var ball: Double = 1
        var lift: CGFloat = 0
        var squash: CGFloat = 1
        var flash: Double = 0
        var number: Double = 1
    }

    /// The marker ball, turned a different way for each day.
    @ViewBuilder
    private func marker(_ day: HomeWeek.Day) -> some View {
        Group {
            if balls.isEmpty {
                Circle().fill(.white)
                    .overlay(Image(systemName: "soccerball").resizable().scaledToFit().foregroundStyle(.black))
            } else {
                Image(decorative: balls[day.id % balls.count], scale: 4).resizable()
            }
        }
        .frame(width: ballSize, height: ballSize)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private func barFill(best: Bool) -> LinearGradient {
        let lime = TrainingHomeStyle.lime
        let green = Color(red: 0.42, green: 0.62, blue: 0.14)
        let colors: [Color] = scheme == .dark
            ? (best ? [lime, Color(red: 0.6, green: 0.82, blue: 0.2)] : [lime.opacity(0.62), green.opacity(0.55)])
            : (best ? [Color(red: 0.7, green: 0.9, blue: 0.24), TrainingHomeStyle.accent(scheme)]
                    : [Color(red: 0.7, green: 0.9, blue: 0.24).opacity(0.6), TrainingHomeStyle.accent(scheme).opacity(0.55)])
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// A bar whose top is pressed in by a round cup the ball sits in; its corners rise
/// on either side. `rimOnly` draws just the cup's curve, for its inner shading.
private struct CupBar: Shape {
    let cupRadius: CGFloat
    let depth: CGFloat
    var rimOnly = false

    func path(in rect: CGRect) -> Path {
        let depth = min(depth, max(0, rect.height - 2))
        let centre = CGPoint(x: rect.midX, y: rect.minY + depth - cupRadius)
        let half = min(rect.width / 2, sqrt(max(0, cupRadius * cupRadius - (cupRadius - depth) * (cupRadius - depth))))
        let from = atan2(rect.minY - centre.y, -half), to = atan2(rect.minY - centre.y, half)
        // Down from the left edge of the cup, through its lowest point, up to the right.
        let cup = (0...16).map { step -> CGPoint in
            let angle = from + (to - from) * CGFloat(step) / 16
            return CGPoint(x: centre.x + cupRadius * cos(angle), y: centre.y + cupRadius * sin(angle))
        }
        var path = Path()
        if rimOnly {
            path.addLines(cup)
            return path
        }
        let corner = min(3, (rect.width / 2 - half) * 0.9)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addQuadCurve(to: CGPoint(x: rect.minX + corner, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        cup.forEach { path.addLine(to: $0) }
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + corner), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Shared pieces

/// Where Home's profile button gets its picture: the account's photo, or the
/// guest's picture saved on this phone (a new version reloads it).
struct HomeProfilePhoto: Hashable {
    var accountPhoto: Data? = nil
    var guestVersion: Int? = nil

    func load() -> UIImage? {
        if let accountPhoto { return UIImage(data: accountPhoto) }
        return guestVersion == nil ? nil : ProfilePhoto.load()
    }
}

/// Observes history so Home updates when a session is saved or removed.
struct HomeSessionsObserver<Content: View>: View {
    @ObservedObject var store: SessionHistoryStore
    @ViewBuilder let content: ([HistorySession]) -> Content

    var body: some View { content(store.items) }
}

#Preview("Training home") {
    RootShellView()
}
