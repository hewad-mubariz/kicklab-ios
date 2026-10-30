import SwiftUI

/// One shared juggling leaderboard, with the top three hung as club pennants.
/// Each period loads once per visit, then updates only on pull-to-refresh.
struct LeaderboardView: View {
    /// The signed-in name, used for your placeholder initials.
    var yourName: String? = nil
    let onClose: () -> Void
    var onRecord: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kicklab.juggling.personalBest") private var personalBest = 0
    @AppStorage("kicklab.profile.displayName") private var displayName = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var player: PlayerStore
    @State private var selection = LeaderboardSelection()
    @StateObject private var boards = LeaderboardBoardStore()
    @State private var hasShownPodium = false
    @State private var appeared = false
    /// True while the pennants make their entrance; rows on screen wait for them.
    @State private var revealing = true
    @State private var youInView = false
    /// Ranks of the rows on screen, so the trip to your row can be paced by distance.
    @State private var visibleRanks: Set<Int> = []
    /// Counts arrivals at your row; each one pulses it.
    @State private var arrivals = 0
    @State private var showsRules = false
    @State private var showsSubmissions = false
    @State private var selectedEntry: LeaderboardEntry?
    @State private var recordAfterSubmissions = false
    /// The session whose left-out touches are open for a check.
    @State private var checking: CheckedSession?
    /// Your checks not decided yet, kept in step with the review store.
    @State private var openChecks: [LeaderboardOpenCheck] = []
    @State private var scrollPosition = ScrollPosition(edge: .top)
    #if DEBUG
    @AppStorage(LeaderboardPreviewScenario.defaultsKey) private var previewScenario = LeaderboardPreviewScenario.live
    #endif

    private static let youAnchor = "leaderboard-you-anchor"

    private var usesSamples: Bool {
        #if DEBUG
        previewScenario != .live || ProcessInfo.processInfo.arguments.contains("--leaderboard-samples")
        #else
        false
        #endif
    }
    private var viewerID: String {
        "\(player.userID?.uuidString ?? "guest")|\(player.profile?.leaderboardVisible ?? false)"
    }
    private var requestID: String {
        var value = "\(selection.period.rawValue)|\(viewerID)"
        #if DEBUG
        value += "|\(previewScenario.rawValue)"
        #endif
        return value
    }

    private var boardState: LeaderboardBoardStore.State {
        #if DEBUG
        if previewScenario != .live {
            return .init(board: previewScenario.board(period: selection.period))
        }
        if usesSamples {
            let name = player.profile?.displayName ?? yourName ?? displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let best = player.userID == nil ? personalBest : player.personalBest
            return .init(board: LeaderboardBoard(
                entries: LeaderboardSample.board(selection, personalBest: best, yourName: name), around: []))
        }
        #endif
        return boards.state(for: selection.period, viewer: viewerID)
    }
    private var entries: [LeaderboardEntry] { boardState.board?.entries ?? [] }
    private var aroundYou: [LeaderboardEntry] { boardState.board?.around ?? [] }
    private var you: LeaderboardEntry? { (entries + aroundYou).first(where: \.isYou) }
    /// The leader's streak; every track measures against it.
    private var best: Int { entries.first?.touches ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .sessionEntrance(appeared, offset: -10)
                    LeaderboardPeriodSwitch(period: $selection.period)
                        .padding(.top, 18)
                        .sessionEntrance(appeared, order: 1, offset: -10)
                    if !usesSamples {
                        LeaderboardJoinCard()
                            .padding(.top, 18)
                        if LeaderboardRules.touchChecks {
                            LeaderboardLastSessionCard(review: player.leaderboardReview, history: player.history) {
                                checking = CheckedSession(id: $0)
                            }
                            .padding(.top, 14)
                        }
                    }
                    if boardState.board == nil, let loadError = boardState.error {
                        ContentUnavailableView {
                            Label("Rankings unavailable", systemImage: "wifi.exclamationmark")
                        } description: { Text(loadError) } actions: {
                            Button("Try again") { Task { await loadBoard(refresh: true) } }.appGlassButtonStyle()
                        }
                    } else if boardState.board == nil {
                        LeaderboardLoadingBall()
                            .frame(maxWidth: .infinity).padding(.top, 70)
                            .accessibilityIdentifier("leaderboard-loading")
                    } else if entries.isEmpty {
                        emptyBoard.padding(.top, 26)
                    } else {
                        pennants(Array(entries.prefix(3))).padding(.top, 26)
                        rows.padding(.top, 24)
                        yourPlace
                    }
                    if usesSamples {
                        Label("Temporary preview · all players, scores and streak statistics are fictional.", systemImage: "eye")
                            .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme)).padding(.top, 24)
                            .accessibilityIdentifier("leaderboard-preview-label")
                    } else {
                        if let onRecord {
                            Button(action: onRecord) {
                                Label("Record a session", systemImage: "video.fill")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                                    // Dark ink on the lime of dark mode, as on Home; white on light mode's olive.
                                    .foregroundStyle(scheme == .dark ? TrainingHomeStyle.buttonInk : .white)
                            }
                            .buttonStyle(.borderedProminent).tint(TrainingHomeStyle.accent(scheme))
                            .padding(.top, 24).accessibilityIdentifier("leaderboard-record")
                        }
                        if LeaderboardRules.touchChecks {
                            Button("Touch checks") { showsSubmissions = true }
                                .frame(maxWidth: .infinity, minHeight: 44).padding(.top, onRecord == nil ? 20 : 0)
                                .accessibilityIdentifier("leaderboard-my-submissions")
                        }
                    }
                    Text(LeaderboardRules.touchChecks
                         ? "Ranked by each player’s best continuous streak, counted automatically. A hand, a catch or a ground touch ends a streak. Touches the counter wasn’t sure of are left out without ending it, and you can send them for a check. Duration and rhythm don’t add points."
                         : "Ranked by each player’s best continuous streak, counted automatically. A hand, a catch or a ground touch ends a streak. Touches the counter wasn’t sure of are left out without ending it. Duration and rhythm don’t add points.")
                        .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 20)
                    if boardState.board != nil, boardState.error != nil {
                        Text("Couldn’t refresh. Showing saved rankings—pull down to try again.")
                            .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                            .padding(.top, 16)
                            .accessibilityIdentifier("leaderboard-refresh-error")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack { youPill(proxy) }
                    .animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion), value: showsYouPill)
            }
        }
        .background { LeaderboardPaper() }
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        // A downward pull belongs to refresh, including short one-player boards.
        // Keep the explicit back button instead of the zoom's swipe-to-dismiss.
        .interactiveDismissDisabled()
        .onChange(of: selection) { _, _ in
            scrollPosition.scrollTo(edge: .top)
        }
        #if DEBUG
        .onChange(of: previewScenario) { _, _ in
            selectedEntry = nil
            scrollPosition.scrollTo(edge: .top)
        }
        #endif
        .task(id: requestID) { await loadBoard() }
        .task(id: viewerID) { if LeaderboardRules.touchChecks, !usesSamples { await player.leaderboardReview.refresh() } }
        .onReceive(player.leaderboardReview.$revision) { _ in openChecks = player.leaderboardReview.openChecks }
        .refreshable { await loadBoard(refresh: true); await player.leaderboardReview.refresh() }
        .sheet(isPresented: $showsRules) { LeaderboardRulesView() }
        .sheet(item: $selectedEntry) { entry in LeaderboardPlayerDetailView(entry: entry, review: player.leaderboardReview) }
        .sheet(item: $checking, onDismiss: { Task { await loadBoard(refresh: true) } }) { session in
            NavigationStack {
                LeaderboardCorrectionView(sessionID: session.id, review: player.leaderboardReview, history: player.history)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { checking = nil } } }
            }
        }
        .sheet(isPresented: $showsSubmissions, onDismiss: {
            Task { await loadBoard(refresh: true) }
            if recordAfterSubmissions { recordAfterSubmissions = false; onRecord?() }
        }) {
            LeaderboardSubmissionsView(review: player.leaderboardReview, history: player.history,
                onRecord: onRecord.map { _ in { recordAfterSubmissions = true; showsSubmissions = false } })
        }
        .task {
            guard !appeared else { return }
            appeared = true
            try? await Task.sleep(for: .seconds(1.4))
            revealing = false
        }
        // Contain, so the screen's identifier does not replace the ones inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("leaderboard-screen")
        .accessibilityAction(.escape, close)
    }

    private func close() {
        dismiss()
        onClose()
    }

    // MARK: - Header

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .appGlass(in: .circle, interactive: true)
            .accessibilityLabel("Close leaderboard")
            .accessibilityIdentifier("leaderboard-close")
            Spacer()
            Button("Rules") { showsRules = true }.font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("leaderboard-rules-link")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4).padding(.bottom, 6)
        .background {
            LinearGradient(stops: [.init(color: LeaderboardStyle.paper(scheme), location: 0.55),
                                   .init(color: LeaderboardStyle.paper(scheme).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -18)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("JUGGLING  ·  BEST STREAKS")
                .font(.caption.weight(.heavy)).tracking(1.6)
                .foregroundStyle(LeaderboardStyle.olive(scheme))
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("Leaderboard")
                    .font(.system(size: 42, weight: .heavy)).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                // The full stop is a ball, kicked up whenever the period changes.
                LeaderboardBall(size: 20)
                    .keyframeAnimator(initialValue: TitleKick(), trigger: reduceMotion ? .week : selection.period) { ball, kick in
                        ball.rotationEffect(.degrees(kick.spin)).offset(y: kick.lift)
                    } keyframes: { start in
                        KeyframeTrack(\.lift) {
                            LinearKeyframe(-22, duration: 0.2, timingCurve: .easeOut)
                            LinearKeyframe(0, duration: 0.2, timingCurve: .easeIn)
                            LinearKeyframe(-6, duration: 0.1, timingCurve: .easeOut)
                            LinearKeyframe(0, duration: 0.1, timingCurve: .easeIn)
                        }
                        KeyframeTrack(\.spin) {
                            LinearKeyframe(start.spin + 360, duration: 0.6, timingCurve: .easeOut)
                        }
                    }
                    .padding(.bottom, 9)
            }
            if usesSamples {
                Text("SAMPLE DATA · DESIGN PREVIEW")
                    .font(.caption2.weight(.bold)).foregroundStyle(LeaderboardStyle.olive(scheme))
            }
            resetChip.padding(.top, 6)
        }
    }

    /// This week counts down to the reset; all time has no end.
    @ViewBuilder private var resetChip: some View {
        if selection.period == .week {
            TimelineView(.everyMinute) { context in
                let reset = LeaderboardRules.nextReset(after: context.date)
                let left = Duration.seconds(max(60, reset.timeIntervalSince(context.date)))
                chip("Resets in \(left.formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))",
                     systemImage: "timer")
                    .accessibilityLabel("Resets \(reset.formatted(date: .abbreviated, time: .shortened)), your time")
            }
            .transition(.opacity)
        } else {
            chip("Best streaks ever", systemImage: "infinity")
                .transition(.opacity)
        }
    }

    private func chip(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(TrainingHomeStyle.muted(scheme))
            .padding(.horizontal, 11).frame(height: 28)
            .background(LeaderboardStyle.card(scheme), in: .capsule)
            .overlay { Capsule().strokeBorder(LeaderboardStyle.line(scheme)) }
    }

    // MARK: - Board

    private func pennants(_ top: [LeaderboardEntry]) -> some View {
        LeaderboardPennants(entries: top, animateEntrance: !hasShownPodium) { selectedEntry = $0 }
            .onAppear { hasShownPodium = true }
    }

    private var emptyBoard: some View {
        VStack(spacing: 20) {
            pennants([])
            VStack(spacing: 6) {
                Text("Be the first on the board").font(.title3.bold())
                Text("Join the leaderboard and record while signed in. Your best streak appears after syncing.")
                    .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("leaderboard-empty")
    }

    /// A plain stack: there are few rows, and every one must exist for the trip to yours.
    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.rank) { index, entry in
                row(entry, delay: revealing ? 0.45 + Double(min(index, 5)) * 0.07 : 0.05)
                    .sessionEntrance(appeared, order: min(index, 6) + 3, offset: -16)
            }
        }
    }

    private func row(_ entry: LeaderboardEntry, delay: Double = 0.05) -> some View {
        let ahead = entry.isYou ? self.ahead(of: entry) : nil
        let check = openCheck(for: entry)
        return Button { selectedEntry = entry } label: {
            LeaderboardRow(entry: entry, best: best,
                           chase: ahead.map { String(localized: "\($0.touches - entry.touches + 1) to pass \($0.name)", bundle: AppLanguage.bundle, locale: AppLanguage.locale) },
                           target: ahead?.touches,
                           review: check?.label(beside: entry.touches, ranked: entry.sessionID),
                           pending: check.flatMap { $0.count > entry.touches ? $0.count : nil },
                           delay: delay, arrivals: entry.isYou ? arrivals : 0)
        }
        .buttonStyle(SessionPressStyle(scale: 0.97))
        .id(anchor(for: entry))
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            if visible { visibleRanks.insert(entry.rank) } else { visibleRanks.remove(entry.rank) }
            if entry.isYou { youInView = visible }
        }
    }

    /// A check still open beside your score. Your score stays the device's streak until it's decided.
    private func openCheck(for entry: LeaderboardEntry) -> LeaderboardOpenCheck? {
        guard LeaderboardRules.touchChecks, entry.isYou else { return nil }
        #if DEBUG
        if previewScenario == .inReview {
            return LeaderboardOpenCheck(sessionID: UUID(), touches: 3, count: entry.touches + 3, sending: false)
        }
        #endif
        return usesSamples ? nil : openChecks.beside(entry)
    }

    private func anchor(for entry: LeaderboardEntry) -> String {
        entry.isYou ? Self.youAnchor : "leaderboard-rank-\(entry.rank)"
    }

    /// The rows below the pennants, in the order they are listed.
    private var listed: [LeaderboardEntry] {
        let rows = Array(entries.dropFirst(3))
        guard !entries.contains(where: \.isYou) else { return rows }
        return rows + aroundYou.filter { neighbor in !entries.contains(where: { $0.rank == neighbor.rank }) }
    }

    /// Keep ranks together from the top. Only append a separate personal result
    /// when it falls outside the fetched leaders; never duplicate a podium place.
    @ViewBuilder private var yourPlace: some View {
        if let you {
            if !entries.contains(where: \.isYou) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR PLACE")
                        .font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(LeaderboardStyle.olive(scheme))
                    VStack(spacing: 10) {
                        ForEach(aroundYou.filter { neighbor in !entries.contains(where: { $0.rank == neighbor.rank }) }) { neighbor in
                            row(neighbor)
                                .accessibilityIdentifier(neighbor.isYou ? "leaderboard-you" : "leaderboard-neighbor-\(neighbor.rank)")
                        }
                    }
                }
                .padding(.top, 24)
            }
        } else {
                LeaderboardUnranked(message: usesSamples ? "Sample board · scores for design review only."
                    : player.userID == nil ? "Sign in, then record a session to get on the board."
                    : player.profile?.leaderboardVisible != true ? "You’re hidden from the board. Turn on leaderboard visibility in Profile."
                    : "Record a session. Your best streak shows up here once it syncs.")
                    .padding(.top, 20)
        }
    }

    private func ahead(of you: LeaderboardEntry) -> LeaderboardEntry? {
        guard you.rank > 1 else { return nil }
        return (entries + aroundYou).first(where: { $0.rank == you.rank - 1 })
    }

    // MARK: - You

    /// Your place, kept in reach while your row is off screen. Not shown when you hang among the top three.
    private var showsYouPill: Bool {
        guard let you, !revealing, !youInView else { return false }
        return !entries.prefix(3).contains(where: \.isYou) && you.rank > 3
    }

    /// How many rows lie between your row and those on screen, and which way.
    /// With no rows on screen the pennants are, just above the first row.
    private var youDistance: (rows: Int, below: Bool)? {
        guard let index = listed.firstIndex(where: \.isYou) else { return nil }
        let shown = listed.indices.filter { visibleRanks.contains(listed[$0].rank) }
        guard let top = shown.min(), let bottom = shown.max() else { return (index + 1, true) }
        return index > bottom ? (index - bottom, true) : (max(0, top - index), false)
    }

    /// Short trips glide, taking longer the further they go. Long ones cut to a few
    /// rows short of yours and glide the rest, so they stay quick but you still see
    /// where you land. Your row pulses on arrival.
    private func scrollToYou(_ proxy: ScrollViewProxy) {
        guard let distance = youDistance, let index = listed.firstIndex(where: \.isYou) else { return }
        guard !reduceMotion else {
            proxy.scrollTo(Self.youAnchor, anchor: .center)
            arrivals += 1
            return
        }
        let glide = min(distance.rows, 3)
        if distance.rows > 4 {
            let lead = listed[distance.below ? max(index - glide, 0) : min(index + glide, listed.count - 1)]
            proxy.scrollTo(anchor(for: lead), anchor: .center)
        }
        // Let the cut land before the glide starts from it.
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.3 + 0.1 * Double(glide))) {
                proxy.scrollTo(Self.youAnchor, anchor: .center)
            } completion: {
                arrivals += 1
            }
        }
    }

    /// How many more your score would be if your open check is confirmed.
    private func pillReview(_ you: LeaderboardEntry) -> Int? {
        guard let check = openCheck(for: you), check.count > you.touches else { return nil }
        return check.count - you.touches
    }

    @ViewBuilder private func youPill(_ proxy: ScrollViewProxy) -> some View {
        if showsYouPill, let you {
            Button { scrollToYou(proxy) } label: {
                HStack(spacing: 10) {
                    LeaderboardMedallion(entry: you, size: 32, ring: LeaderboardStyle.lime, ringWidth: 2)
                    Text("You").font(.subheadline.weight(.semibold))
                    Text("#\(you.rank)").font(LeaderboardStyle.number(22)).padding(.top, 3)
                        .foregroundStyle(TrainingHomeStyle.accent(scheme))
                    Text(you.touches.formatted()).font(LeaderboardStyle.number(22)).padding(.top, 3)
                    if let more = pillReview(you) {
                        Label("+\(more)", systemImage: "hourglass")
                            .font(.caption.weight(.bold)).monospacedDigit()
                            .foregroundStyle(TrainingHomeStyle.muted(scheme))
                    }
                    Image(systemName: youDistance?.below ?? true ? "arrow.down" : "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.leading, 6).padding(.trailing, 16).frame(height: 46)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .appGlass(in: .capsule, interactive: true)
            .padding(.bottom, 6)
            .transition(.sessionRise)
            .accessibilityLabel([String(localized: "Jump to your place, rank \(you.rank), \(you.touches) touches", bundle: AppLanguage.bundle, locale: AppLanguage.locale),
                                 pillReview(you).map { String(localized: "\($0) more in review", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("leaderboard-you-pill")
        }
    }

    private func loadBoard(refresh: Bool = false) async {
        guard !usesSamples else { return }
        let period = selection.period
        await boards.load(period, viewer: viewerID, refresh: refresh) {
            #if DEBUG
            if let count = LeaderboardReview.count {
                let board = try await LeaderboardReview.board(count: count, period: period)
                return LeaderboardBoard(entries: board.entries, around: board.around)
            }
            #endif
            let board = try await player.leaderboard(period: period)
            return LeaderboardBoard(entries: board.entries, around: board.around)
        }
    }
}

private struct RowArrival {
    var scale: CGFloat = 1
    var ring: Double = 0
    var spread: CGFloat = 0
}

private struct TitleKick {
    var lift: CGFloat = 0
    var spin: Double = 0
}

/// The two periods in one track, the lit pill sliding between them.
struct LeaderboardPeriodSwitch: View {
    @Binding var period: LeaderboardPeriod
    @Environment(\.colorScheme) private var scheme
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LeaderboardPeriod.allCases) { option in
                let selected = option == period
                Button {
                    withAnimation(SessionMotion.snap) { period = option }
                } label: {
                    Text(option.title.uppercased())
                        .font(LeaderboardStyle.number(19)).tracking(1.4)
                        .padding(.top, 3)
                        .foregroundStyle(selected ? selectedInk : TrainingHomeStyle.muted(scheme))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background {
                            if selected {
                                Capsule().fill(selectedFill)
                                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("leaderboard-period-\(option == .week ? "week" : "all-time")")
            }
        }
        .padding(4)
        .background(LeaderboardStyle.line(scheme).opacity(scheme == .dark ? 0.6 : 0.55), in: .capsule)
        .overlay { Capsule().strokeBorder(LeaderboardStyle.line(scheme)) }
        .sensoryFeedback(.selection, trigger: period)
    }

    private var selectedFill: Color { scheme == .dark ? LeaderboardStyle.lime : TrainingHomeStyle.ink(.light) }
    private var selectedInk: Color { scheme == .dark ? TrainingHomeStyle.buttonInk : LeaderboardStyle.lime }
}

struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    /// The leader's streak; the track measures this one against it.
    var best: Int
    var chase: String? = nil
    /// The streak of the next player up, flagged on your track.
    var target: Int? = nil
    /// A touch check still open on your score, in words.
    var review: String? = nil
    /// Your streak if that check is confirmed, shown faintly ahead of the ball.
    var pending: Int? = nil
    /// Rows on screen at the reveal wait for the pennants before rolling.
    var delay: Double = 0.05
    /// Each change pulses the row: you've just arrived at it.
    var arrivals = 0
    @State private var rolled = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { entry.isYou }
    private var shown: Int { rolled ? entry.touches : 0 }

    /// Whole phrases joined by full stops, so each language keeps its own word order.
    private var spokenRow: String {
        var rank = String(localized: "Rank \(entry.rank), \(lit ? String(localized: "you") : entry.name), \(entry.touches) touches", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        if entry.hasConfirmedTouchCheck { rank += ", " + String(localized: "confirmed by a reviewer", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }
        let stats = String(localized: "Streak duration \(entry.streakDurationLabel), average rhythm \(entry.averageRhythmLabel)", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        return [rank, review, stats, chase].compactMap { $0 }.joined(separator: ". ")
    }

    private func share(_ touches: Int) -> Double {
        best > 0 ? min(1, Double(touches) / Double(best)) : 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(entry.rank)")
                .font(LeaderboardStyle.number(entry.rank > 99 ? 19 : 24))
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 13)
                .frame(width: 32)
                .opacity(lit ? 1 : 0.55)
            LeaderboardMedallion(entry: entry, size: 44,
                                 ring: lit ? Color(red: 0.18, green: 0.25, blue: 0.07) : LeaderboardStyle.line(scheme),
                                 ringWidth: lit ? 2.5 : 1.5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(lit ? String(localized: "You", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : entry.name).font(.body.weight(.semibold)).lineLimit(1)
                    if entry.hasConfirmedTouchCheck {
                        // Only a score a reviewer confirmed carries the seal.
                        Image(systemName: "checkmark.seal.fill").font(.caption)
                    }
                    Spacer(minLength: 8)
                    Text(shown.formatted())
                        .font(LeaderboardStyle.number(28))
                        .contentTransition(.numericText(value: Double(shown)))
                }
                if let review {
                    Label(review, systemImage: "hourglass")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.black.opacity(lit ? 0.1 : 0.06), in: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                LeaderboardStreakTrack(share: rolled ? share(entry.touches) : 0,
                                       target: target.map(share),
                                       pending: rolled ? pending.map(share) : nil, lit: lit)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Label(entry.streakDurationLabel, systemImage: "timer")
                        Label(entry.averageRhythmLabel, systemImage: "metronome")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Label(entry.streakDurationLabel, systemImage: "timer")
                        Label(entry.averageRhythmLabel, systemImage: "metronome")
                    }
                }.font(.caption).opacity(0.7)
                if let chase {
                    Label(chase, systemImage: "flag.fill")
                        .font(.caption.weight(.semibold)).opacity(0.75)
                        .contentTransition(.interpolate)
                }
            }
        }
        .foregroundStyle(lit ? LeaderboardStyle.ink : TrainingHomeStyle.ink(scheme))
        .padding(.leading, 10).padding(.trailing, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(lit
                      ? AnyShapeStyle(LinearGradient(colors: [LeaderboardStyle.lime, LeaderboardStyle.limeDeep],
                                                     startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(LeaderboardStyle.card(scheme)))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(lit ? .white.opacity(0.35) : LeaderboardStyle.line(scheme)) }
        .clipShape(.rect(cornerRadius: 20))
        .keyframeAnimator(initialValue: RowArrival(), trigger: reduceMotion ? 0 : arrivals) { row, arrival in
            row.scaleEffect(arrival.scale)
                .overlay {
                    RoundedRectangle(cornerRadius: 20 + arrival.spread)
                        .stroke(TrainingHomeStyle.accent(scheme), lineWidth: 3)
                        .padding(-arrival.spread)
                        .opacity(arrival.ring)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.04, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
            // A ring ripples out from the row and fades.
            KeyframeTrack(\.ring) {
                LinearKeyframe(1, duration: 0.06)
                LinearKeyframe(0, duration: 0.7, timingCurve: .easeOut)
            }
            KeyframeTrack(\.spread) {
                LinearKeyframe(0, duration: 0.01)
                LinearKeyframe(14, duration: 0.75, timingCurve: .easeOut)
            }
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: arrivals)
        // Roll when the row first comes on screen, not when it is built.
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            guard visible, !rolled else { return }
            if reduceMotion { rolled = true; return }
            withAnimation(.spring(response: 0.95, dampingFraction: 0.7).delay(delay)) { rolled = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenRow)
        .accessibilityIdentifier("leaderboard-row-\(entry.rank)")
    }
}

/// A streak as distance: a ball rolls out to the player's share of the leader's
/// streak, turning as it goes. A flag can mark the next player to pass.
struct LeaderboardStreakTrack: View {
    let share: Double
    var target: Double? = nil
    /// Where the ball would be if an open touch check is confirmed.
    var pending: Double? = nil
    var lit = false
    @Environment(\.colorScheme) private var scheme

    private let ball: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - ball)
            let x = travel * share
            ZStack(alignment: .bottomLeading) {
                Capsule().fill(lit ? Color.black.opacity(0.12) : LeaderboardStyle.line(scheme))
                    .frame(height: 5).padding(.bottom, 5.5)
                if let pending {
                    // Dashed, because it isn't counted until a reviewer confirms it.
                    Capsule().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                        .foregroundStyle(lit ? LeaderboardStyle.ink.opacity(0.55) : TrainingHomeStyle.accent(scheme))
                        .frame(width: travel * pending + ball / 2, height: 5).padding(.bottom, 5.5)
                }
                Capsule().fill(fill)
                    .frame(width: x + ball / 2, height: 5).padding(.bottom, 5.5)
                if let target {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.bottom, 8)
                        .offset(x: travel * target + ball / 2 - 1.5)
                }
                // Offset and turn share one curve, so the ball rolls without sliding.
                LeaderboardBall(size: ball)
                    .rotationEffect(.radians(Double(x / (ball / 2))))
                    .offset(x: x)
            }
        }
        .frame(height: target == nil ? ball : ball + 9)
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        if lit { return AnyShapeStyle(LeaderboardStyle.ink.opacity(0.75)) }
        let accent = TrainingHomeStyle.accent(scheme)
        return AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.45), accent], startPoint: .leading, endPoint: .trailing))
    }
}

/// A ball bouncing in place while rankings load.
private struct LeaderboardLoadingBall: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let period = 0.64
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                // A parabola: on the ground at both ends of each bounce, flattening as it lands.
                let height = reduceMotion ? 0 : 4 * phase * (1 - phase)
                let squash = 1 - max(0, 0.1 - height) * 1.6
                ZStack(alignment: .bottom) {
                    Ellipse().fill(.black.opacity(0.2 - height * 0.12))
                        .frame(width: 30 - height * 12, height: 6)
                    LeaderboardBall(size: 30)
                        .rotationEffect(.degrees(phase * 200))
                        .scaleEffect(x: 2 - squash, y: squash, anchor: .bottom)
                        .offset(y: -3 - height * 58)
                }
                .frame(height: 96, alignment: .bottom)
            }
            Text("Loading rankings…").font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
        }
        .accessibilityElement(children: .combine)
    }
}

/// No record yet: a nudge in place of your row.
private struct CheckedSession: Identifiable { let id: UUID }

private struct LeaderboardUnranked: View {
    var message: LocalizedStringKey = "Record a juggling session to get on the board."

    var body: some View {
        HStack(spacing: 12) {
            LeaderboardBall(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("You’re not ranked yet").font(.body.weight(.semibold))
                Text(message).font(.caption).opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(LeaderboardStyle.ink)
        .padding(.horizontal, 18).frame(minHeight: 68)
        .background(LeaderboardStyle.lime, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("leaderboard-you")
    }
}

/// Paper with a faint grain, drawn once.
private struct LeaderboardPaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LeaderboardStyle.paper(scheme)
            Canvas { context, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                }
                let count = Int(size.width * size.height / 90)
                for index in 0..<count {
                    let point = CGPoint(x: next() * size.width, y: next() * size.height)
                    let dot = 0.6 + next() * 0.9
                    let tone: Color = index % 2 == 0 ? .black : .white
                    context.fill(Path(ellipseIn: CGRect(origin: point, size: CGSize(width: dot, height: dot))),
                                 with: .color(tone.opacity(scheme == .dark ? 0.05 : 0.045)))
                }
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview("Leaderboard") { LeaderboardView(onClose: {}).environmentObject(PlayerStore(service: nil)) }
