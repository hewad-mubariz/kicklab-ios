import SwiftUI

/// One shared juggling leaderboard, with the top three hung as club pennants.
/// Each period loads once per visit, then updates only on pull-to-refresh.
struct LeaderboardView: View {
    /// The signed-in name, used for your placeholder initials.
    var yourName: String? = nil
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kicklab.juggling.personalBest") private var personalBest = 0
    @AppStorage("kicklab.profile.displayName") private var displayName = ""
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var player: PlayerStore
    @State private var selection = LeaderboardSelection()
    @StateObject private var boards = LeaderboardBoardStore()
    @State private var hasShownPodium = false
    @State private var appeared = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private var usesSamples: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--leaderboard-samples")
        #else
        false
        #endif
    }
    private var viewerID: String {
        "\(player.userID?.uuidString ?? "guest")|\(player.profile?.leaderboardVisible ?? false)"
    }
    private var requestID: String { "\(selection.period.rawValue)|\(viewerID)" }

    private var boardState: LeaderboardBoardStore.State {
        #if DEBUG
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .sessionEntrance(appeared, offset: -10)
                LeaderboardPeriodSwitch(period: $selection.period)
                    .padding(.top, 18)
                    .sessionEntrance(appeared, order: 1, offset: -10)
                if boardState.board == nil, let loadError = boardState.error {
                    ContentUnavailableView {
                        Label("Rankings unavailable", systemImage: "wifi.exclamationmark")
                    } description: { Text(loadError) } actions: {
                        Button("Try again") { Task { await loadBoard(refresh: true) } }.buttonStyle(.glass)
                    }
                } else if boardState.board == nil {
                    ProgressView("Loading rankings…").frame(maxWidth: .infinity).padding(.top, 80)
                        .accessibilityIdentifier("leaderboard-loading")
                } else if entries.isEmpty {
                    ContentUnavailableView("Be the first on the board", systemImage: "figure.soccer",
                        description: Text("Record a juggling session and turn on leaderboard sharing in Profile."))
                        .accessibilityIdentifier("leaderboard-empty")
                } else {
                    pennants.padding(.top, 50)
                    rows.padding(.top, 26)
                    yourPlace
                }
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
        .background { LeaderboardPaper() }
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        // A downward pull belongs to refresh, including short one-player boards.
        // Keep the explicit back button instead of the zoom's swipe-to-dismiss.
        .interactiveDismissDisabled()
        .onChange(of: selection) { _, _ in
            scrollPosition.scrollTo(edge: .top)
        }
        .task(id: requestID) { await loadBoard() }
        .refreshable { await loadBoard(refresh: true) }
        .task {
            guard !appeared else { return }
            appeared = true
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
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close leaderboard")
            .accessibilityIdentifier("leaderboard-close")
            Spacer()
            if usesSamples {
                Text("10-player preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LeaderboardStyle.olive(scheme))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(LeaderboardStyle.card(scheme), in: .capsule)
                    .accessibilityIdentifier("leaderboard-preview-label")
            }
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
            Text("JUGGLING")
                .font(.caption.weight(.heavy)).tracking(1.8)
                .foregroundStyle(LeaderboardStyle.olive(scheme))
            Text("Leaderboard")
                .font(.system(size: 42, weight: .heavy)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(selection.period == .week ? "BEST SESSION  ·  TOUCHES  ·  MONDAY UTC" : "BEST SESSION EVER  ·  TOUCHES")
                .font(.caption2.weight(.bold)).tracking(1.3)
                .foregroundStyle(TrainingHomeStyle.muted(scheme))
                .contentTransition(.interpolate)
                .animation(SessionMotion.fade, value: selection.period)
        }
    }

    // MARK: - Board

    private var pennants: some View {
        let top = Array(entries.prefix(3))
        return GeometryReader { geometry in
            let width = min(124, (geometry.size.width - 2 * 12 - 3 * 14) / 3)
            HStack(alignment: .top, spacing: 12) {
                if top.count > 1 { pennant(top[1], width: width, height: 226, delay: 0.04, side: -1) }
                if let first = top.first { pennant(first, width: width, height: 258, delay: 0.26, side: 1) }
                if top.count > 2 { pennant(top[2], width: width, height: 226, delay: 0.13, side: 1) }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 262)
        .onAppear { hasShownPodium = true }
    }

    private func pennant(_ entry: LeaderboardEntry, width: CGFloat, height: CGFloat, delay: Double, side: Double) -> some View {
        LeaderboardPennant(entry: entry, width: width, height: height,
                           animateEntrance: !hasShownPodium, delay: delay, side: side)
    }

    private var rows: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.rank) { index, entry in
                LeaderboardRow(entry: entry)
                    .sessionEntrance(appeared, order: min(index, 6) + 3, offset: -16)
            }
        }
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
                    LeaderboardRow(entry: you, chase: chase(for: you))
                        .accessibilityIdentifier("leaderboard-you")
                }
                .padding(.top, 24)
            }
        } else {
                LeaderboardUnranked(message: usesSamples ? "Record a juggling session to get on the board."
                    : player.userID == nil ? "Sign in through Profile to save your results."
                    : player.profile?.leaderboardVisible != true ? "Turn on leaderboard sharing in Profile."
                    : "Record a juggling session to get on the board.")
                    .padding(.top, 20)
        }
    }

    private func chase(for you: LeaderboardEntry) -> String? {
        guard you.rank > 1, let ahead = (entries + aroundYou).first(where: { $0.rank == you.rank - 1 }) else { return nil }
        return "\(ahead.touches - you.touches + 1) to pass \(ahead.name)"
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
                    Text(option.rawValue.uppercased())
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
    var chase: String? = nil
    @Environment(\.colorScheme) private var scheme

    private var lit: Bool { entry.isYou }

    var body: some View {
        HStack(spacing: 14) {
            LeaderboardRankTab(rank: entry.rank, highlighted: lit)
                .padding(.top, -6)
                .frame(maxHeight: .infinity, alignment: .top)
            LeaderboardMedallion(entry: entry, size: 42,
                                 ring: lit ? Color(red: 0.18, green: 0.25, blue: 0.07) : LeaderboardStyle.line(scheme),
                                 ringWidth: lit ? 2.5 : 1.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(lit ? "You" : entry.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let chase {
                    Text(chase).font(.caption.weight(.semibold)).opacity(0.7)
                        .contentTransition(.interpolate)
                }
            }
            Spacer(minLength: 8)
            Text(entry.touches.formatted())
                .font(LeaderboardStyle.number(30))
                .padding(.top, 4)
                .contentTransition(.numericText(value: Double(entry.touches)))
        }
        .foregroundStyle(lit ? Color(red: 0.09, green: 0.12, blue: 0.06) : TrainingHomeStyle.ink(scheme))
        .padding(.leading, 12).padding(.trailing, 18)
        .frame(height: 62)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(lit
                      ? AnyShapeStyle(LinearGradient(colors: [LeaderboardStyle.lime, LeaderboardStyle.limeDeep],
                                                     startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(LeaderboardStyle.card(scheme)))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(lit ? .white.opacity(0.35) : LeaderboardStyle.line(scheme)) }
        .clipShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(lit ? "you" : entry.name), \(entry.touches) touches\(chase.map { ". \($0)" } ?? "")")
        .accessibilityIdentifier("leaderboard-row-\(entry.rank)")
    }
}

/// No record yet: a nudge in place of your row.
private struct LeaderboardUnranked: View {
    var message = "Record a juggling session to get on the board."
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.soccer").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("You’re not ranked yet").font(.body.weight(.semibold))
                Text(message).font(.caption).opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.09, green: 0.12, blue: 0.06))
        .padding(.horizontal, 18).frame(height: 68)
        .background(LeaderboardStyle.lime, in: .rect(cornerRadius: 16))
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
