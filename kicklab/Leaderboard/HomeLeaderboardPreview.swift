import SwiftUI

struct HomeLeaderboardPreview: View {
    let onOpen: () -> Void
    let onRules: () -> Void
    @EnvironmentObject private var player: PlayerStore
    var body: some View {
        HomeReviewedLeaderboardCard(review: player.leaderboardReview, onOpen: onOpen, onRules: onRules)
    }
}

private struct HomeReviewedLeaderboardCard: View {
    @ObservedObject var review: LeaderboardReviewStore
    let onOpen: () -> Void
    let onRules: () -> Void
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var boards = LeaderboardBoardStore()
    #if DEBUG
    @AppStorage(LeaderboardPreviewScenario.defaultsKey) private var previewScenario = LeaderboardPreviewScenario.live
    #endif
    private var previewID: String {
        #if DEBUG
        previewScenario.rawValue
        #else
        "live"
        #endif
    }
    private var usesPreview: Bool { previewID != "live" }
    private var viewer: String { "\(player.userID?.uuidString ?? "guest")|\(player.profile?.leaderboardVisible ?? false)" }
    private var state: LeaderboardBoardStore.State {
        #if DEBUG
        if usesPreview { return .init(board: previewScenario.board(period: .week)) }
        #endif
        return boards.state(for: .week, viewer: viewer)
    }
    private var entries: [LeaderboardEntry] { (state.board?.entries ?? []) + (state.board?.around ?? []) }
    private var you: LeaderboardEntry? { entries.first(where: \.isYou) }
    private var pending: Bool { !usesPreview && review.attempts.contains { $0.status == .pending || $0.status == .uploading } }
    /// A touch check kept on this phone until it can send.
    private var waiting: Bool { !usesPreview && !review.queued.isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: "flag.fill").foregroundStyle(TrainingHomeStyle.lime)
                        Text("Leaderboard").font(.title3.bold())
                        Text(usesPreview ? "PREVIEW" : "BETA").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.white.opacity(0.12), in: .capsule)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.subheadline)
                    }
                    if let you {
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 24))
                        layout {
                            metric("#\(you.rank)", "this week")
                            metric(you.touches.formatted(), usesPreview ? "sample touches" : "best streak")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.error != nil ? "Rankings unavailable" : waiting ? "Your touch check is waiting to send"
                                 : pending ? "Your touches are being checked" : "Your first place starts here")
                                .font(.headline)
                            Text(state.error != nil ? "Open the board to try again."
                                 : waiting ? "It sends by itself once you’re online." : "Record a session. Your best streak ranks by itself.")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("home-leaderboard-card")
            Divider().overlay(.white.opacity(0.25)).padding(.horizontal, 18)
            HStack {
                Text(chase).font(.caption).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                Button(action: onRules) { Label("Rules", systemImage: "chevron.right").font(.subheadline.weight(.medium)).frame(minHeight: 44) }
                    .buttonStyle(.plain).accessibilityIdentifier("home-leaderboard-rules")
            }.padding(.horizontal, 18).padding(.vertical, 3)
        }
        .foregroundStyle(.white)
        .background {
            GeometryReader { geometry in
                Image("leaderboard-stadium").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay(.black.opacity(0.18))
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .task(id: "\(viewer)|\(review.revision)|\(previewID)") {
            guard !usesPreview else { return }
            await boards.load(.week, viewer: viewer, refresh: true) {
                let board = try await player.leaderboard(period: .week)
                return LeaderboardBoard(entries: board.entries, around: board.around)
            }
        }
        .task(id: "\(viewer)|\(previewID)") {
            guard !usesPreview else { return }
            await review.refresh()
        }
    }
    private var chase: String {
        if state.error != nil, state.board != nil { return "Saved ranking · open to refresh" }
        if let you, let check = review.openCheck(for: you)?.label(beside: you.touches, ranked: you.sessionID) {
            return check
        }
        guard let you else { return pending || waiting ? "View your touch check" : "Best streaks · weekly & all-time" }
        if you.rank == 1 { return "You lead this week" }
        guard let ahead = entries.first(where: { $0.rank == you.rank-1 }) else { return "View nearby players" }
        return "\(max(1,ahead.touches-you.touches+1)) touches to #\(ahead.rank)"
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(TrainingHomeStyle.display(42, relativeTo: .largeTitle)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.85))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
