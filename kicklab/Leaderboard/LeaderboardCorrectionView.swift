import AVKit
import SwiftUI

/// A recorded session's streak, and the touches the counter left out of it. The player
/// can pick the ones they think were valid and send short clips of them for a check.
struct LeaderboardCorrectionView: View {
    let sessionID: UUID
    @ObservedObject var review: LeaderboardReviewStore
    @ObservedObject var history: SessionHistoryStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let item = history.items.first(where: { $0.id == sessionID && $0.ownerID != nil && $0.ownerID == review.owner }) {
                LeaderboardCorrectionForm(item: item, video: history.replayURL(for: item), review: review, history: history)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "soccerball",
                    description: Text("Sign in with the account that recorded this session."))
            }
        }
        .task { await review.refresh() }
        .onChange(of: review.owner) { _, _ in dismiss() }
    }
}

struct LeaderboardCorrectionForm: View {
    let item: HistorySession
    let video: URL?
    @ObservedObject var review: LeaderboardReviewStore
    var history: SessionHistoryStore? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @State private var chosen: Set<LeaderboardReviewMoment.ID> = []
    @State private var playing: LeaderboardReviewMoment?
    @State private var player: AVPlayer?
    @State private var agreed = false
    @State private var showsRules = false

    private var correction: LeaderboardCorrection? { LeaderboardCorrection(item: item) }
    private var attempt: LeaderboardAttempt? { review.attempt(for: item.id) }
    private var sending: Bool { review.uploadingSession == item.id }
    private var queued: Bool { review.isQueued(item.id) }
    /// The streak the device counted, which is what ranks until a check says otherwise.
    private var counted: Int { item.rankedProposal?.count ?? correction?.counted?.count ?? 0 }
    private var claim: RankedStreakProposal? { chosen.isEmpty ? nil : correction?.streak(counting: chosen) }
    private var gain: Int { (claim?.count ?? counted) - counted }
    /// The number to show beside the device's: what was asked for, confirmed, or would be.
    private var target: Int? {
        if let attempt { return attempt.reviewedCount ?? attempt.proposedCount }
        return claim?.count
    }
    private var muted: Color { TrainingHomeStyle.muted(scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let video, showsPlayer { playerPanel(video) }
                content
            }
            .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.background(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .tint(TrainingHomeStyle.accent(scheme))
        .navigationTitle("Your streak").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsRules) { LeaderboardRulesView() }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: phase) { _, value in if value != .active { player?.pause() } }
        .accessibilityIdentifier("leaderboard-correction")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.completedAt.formatted(date: .abbreviated, time: .shortened).uppercased())
                .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(TrainingHomeStyle.accent(scheme))
            HStack(alignment: .center, spacing: 16) {
                score(counted, "best streak")
                if let target, target != counted {
                    Image(systemName: "arrow.right").font(.title2.weight(.bold)).foregroundStyle(muted)
                        .transition(.scale.combined(with: .opacity))
                    score(target, attempt?.status == .approved ? "confirmed" : attempt == nil ? "if confirmed" : "asked for",
                          highlight: attempt?.status != .rejected && attempt?.status != .withdrawn)
                        .contentTransition(.numericText(value: Double(target)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: target)
            Text(summary).font(.subheadline).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("correction-header")
    }

    private func score(_ value: Int, _ label: LocalizedStringKey, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(LeaderboardStyle.number(56)).monospacedDigit()
                .foregroundStyle(highlight ? TrainingHomeStyle.accent(scheme) : TrainingHomeStyle.ink(scheme))
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(muted)
        }
    }

    /// Whole sentences, so each language can order its own words.
    private var summary: String {
        let total = String(localized: "\(item.touches) touches in all, and your longest run without a stop was \(counted). That run is what ranks.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        guard item.source == .recording else { return String(localized: "Imported videos stay in your history and never rank.", bundle: AppLanguage.bundle, locale: AppLanguage.locale) }
        guard let correction else {
            return [total, String(localized: "This session was saved before touch checks, so there’s nothing to choose.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)].joined(separator: " ")
        }
        var sentences = [total]
        if let stop = correction.endedBy {
            sentences.append(String(localized: "It began at your first counted touch and ended at \(stop.timestamp): \(stop.kind.stopReason).", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        }
        let leftOut = correction.leftOut.count
        sentences.append(leftOut > 0 ? String(localized: "Inside it, the counter left out \(leftOut) touches it wasn’t sure of.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                                     : String(localized: "Every touch inside it was counted.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
        return sentences.joined(separator: " ")
    }

    // MARK: - Recording

    private var showsPlayer: Bool { !(correction?.leftOut.isEmpty ?? true) || attempt?.touchReview?.moments.isEmpty == false }

    private func playerPanel(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoPlayer(player: player)
                .frame(height: 230).clipShape(.rect(cornerRadius: 18))
                .task(id: url) { player?.pause(); player = AVPlayer(url: url) }
                .accessibilityIdentifier("correction-player")
            if let playing {
                Text("\(playing.timestamp) · \(playing.kind.explanation)")
                    .font(.footnote).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tap a moment to watch it, with a second either side.").font(.footnote).foregroundStyle(muted)
            }
        }
    }

    private func play(_ moment: LeaderboardReviewMoment) {
        playing = moment
        guard let player else { return }
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = CMTime(value: Int64(moment.clipEndMS), timescale: 1000)
        player.seek(to: CMTime(value: Int64(moment.clipStartMS), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        if sending {
            panel {
                ProgressView(value: review.progress) { Text(review.phase) }
                Text("If the connection drops, it carries on by itself when you’re back online.").font(.footnote).foregroundStyle(muted)
                Button("Pause sending") { review.pauseUpload() }
            }
        } else if queued {
            panel {
                Label("Waiting to send", systemImage: "icloud.and.arrow.up").font(.headline)
                    .accessibilityIdentifier("leaderboard-waiting-to-send")
                Text(waitingReason).font(.footnote).foregroundStyle(muted)
                Button("Cancel check", role: .destructive) { review.cancelQueued(item.id) }
            }
        } else if let attempt, attempt.status != .uploading {
            status(attempt)
            if let asked = attempt.touchReview?.moments, !asked.isEmpty {
                panel("TOUCHES YOU SENT") { moments(asked, selectable: false) }
            }
        } else if let attempt {
            panel {
                Label("Sending paused", systemImage: "pause.circle").font(.headline)
                Text("Your check for \(attempt.proposedCount) isn’t sent yet.").font(.footnote).foregroundStyle(muted)
                Button("Resume sending") { review.enqueue(item: item, proposal: attempt.proposal, request: attempt.touchReview) }
                    .disabled(video == nil)
            }
        } else if item.source == .recording, let correction, !correction.leftOut.isEmpty {
            if video == nil {
                panel {
                    Label("Recording not on this phone", systemImage: "video.slash").font(.headline)
                    Text("Touches can only be sent from the phone that holds the recording.").font(.footnote).foregroundStyle(muted)
                }
            } else {
                choose(correction)
            }
        }
        if let error = review.errorMessage, !sending {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
    }

    private var waitingReason: LocalizedStringKey {
        if item.syncState != .synced { return "It sends by itself once this session has synced to your account. You can close this screen." }
        if review.waitingForConnection { return "You’re offline. It sends by itself when you’re back online. You can close this screen." }
        return "Sending shortly."
    }

    private func status(_ attempt: LeaderboardAttempt) -> some View {
        let asked = attempt.touchReview?.moments.count ?? 0
        let (title, symbol, detail): (LocalizedStringKey, String, LocalizedStringKey) = switch attempt.status {
        case .approved: ("Confirmed", "checkmark.seal.fill",
                         "A reviewer checked your clips. This session now counts \(attempt.reviewedCount ?? attempt.proposedCount).")
        case .rejected: ("Not confirmed", "xmark.seal",
                         "A reviewer couldn’t confirm the \(asked) touches you sent, so your streak stays at \(counted).")
        case .withdrawn: ("Withdrawn", "arrow.uturn.backward", "You withdrew this check. Your streak stays at \(counted).")
        default: ("Being checked", "clock",
                  "You asked to count \(asked) touches, for a streak of \(attempt.proposedCount). Your rank changes only if a reviewer confirms them.")
        }
        return panel {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if let reason = attempt.reviewReason { Text("“\(reason)”").font(.subheadline) }
            if let history {
                NavigationLink("Details and re-review") {
                    LeaderboardAttemptStatusView(attemptID: attempt.id, review: review, history: history)
                }.font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityIdentifier("correction-status")
    }

    // MARK: - Choosing

    @ViewBuilder private func choose(_ correction: LeaderboardCorrection) -> some View {
        panel("LEFT OUT OF YOUR STREAK", footer: "The counter wasn’t sure of these touches, so it didn’t count them, and they didn’t end your streak. Clear hand touches, catches and bounces aren’t listed: they always end a streak.") {
            moments(correction.leftOut, selectable: true)
        }
        panel {
            Toggle(isOn: $agreed) {
                Text("I used one size-5 football and agree to the leaderboard rules.").font(.subheadline)
            }
            .accessibilityIdentifier("correction-agree")
            Button("Read the rules") { showsRules = true }.font(.subheadline.weight(.semibold))
            Text(clipNote(correction)).font(.footnote).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if !chosen.isEmpty, gain <= 0 {
                Text("These wouldn’t make your best streak any longer, so a check can’t change your rank.")
                    .font(.footnote.weight(.semibold))
            }
            Button(action: send) {
                Text(chosen.isEmpty ? "Choose touches to send" : "Send \(chosen.count) touches for a check")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(scheme == .dark ? TrainingHomeStyle.buttonInk : .white)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!agreed || chosen.isEmpty || gain <= 0)
            .accessibilityIdentifier("correction-send")
        }
    }

    private func clipNote(_ correction: LeaderboardCorrection) -> String {
        let request = correction.request(counting: chosen)
        let windows = claim.map { LeaderboardMomentClips.windows(for: request.moments, proposal: $0, durationMS: item.durationMS) } ?? []
        let seconds = Int((Double(windows.reduce(0) { $0 + $1.durationMS }) / 1000).rounded(.up))
        let size = request.moments.isEmpty
            ? String(localized: "Only short clips around the touches you choose are sent, never the whole recording.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            : String(localized: "Only \(seconds) seconds of clips around the touches you choose are sent, never the whole recording.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        return [size, String(localized: "They’re private to you and the review team. If a reviewer confirms the touches, your streak updates by itself.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)]
            .joined(separator: " ")
    }

    private func send() {
        guard let correction, let claim, claim.count > counted else { return }
        player?.pause()
        review.enqueue(item: item, proposal: claim, request: correction.request(counting: chosen))
    }

    private func moments(_ list: [LeaderboardReviewMoment], selectable: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(list) { moment in
                row(moment, selectable: selectable)
                if moment.id != list.last?.id { Divider() }
            }
        }
    }

    private func row(_ moment: LeaderboardReviewMoment, selectable: Bool) -> some View {
        let on = chosen.contains(moment.id)
        return HStack(spacing: 8) {
            Button { play(moment) } label: {
                HStack(spacing: 12) {
                    Image(systemName: playing?.id == moment.id ? "play.circle.fill" : "play.circle")
                        .font(.title2).foregroundStyle(TrainingHomeStyle.accent(scheme))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(moment.kind.title).font(.subheadline.weight(.semibold))
                        Text(moment.timestamp).font(.caption).monospacedDigit().foregroundStyle(muted)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 48).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(video == nil)
            .accessibilityIdentifier("correction-play-\(moment.id)")
            if selectable {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if on { chosen.remove(moment.id) } else { chosen.insert(moment.id) }
                    }
                } label: {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(on ? TrainingHomeStyle.accent(scheme) : muted)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: on)
                .accessibilityLabel("Count the touch at \(moment.timestamp)")
                .accessibilityValue(on ? "Chosen" : "Not chosen")
                .accessibilityIdentifier("correction-count-\(moment.id)")
            }
        }
    }

    private func panel<Content: View>(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(muted)
            }
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TrainingHomeStyle.line(scheme)))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Leaderboard cards

/// Your latest recorded session, while it has touches worth a look or a check under way.
struct LeaderboardLastSessionCard: View {
    @ObservedObject var review: LeaderboardReviewStore
    @ObservedObject var history: SessionHistoryStore
    let open: (UUID) -> Void
    @Environment(\.colorScheme) private var scheme
    /// The last session the player said looked right, so it isn't offered again.
    @AppStorage("kicklab.leaderboard.lookedRight") private var lookedRight = ""

    private var latest: HistorySession? {
        history.items.filter { $0.ownerID != nil && $0.ownerID == review.owner && $0.source == .recording }
            .max { $0.completedAt < $1.completedAt }
    }

    var body: some View {
        if let latest, let line = line(for: latest) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    LeaderboardBall(size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.title).font(.headline)
                        Text(line.detail).font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    if line.asks {
                        Button("Looks right") {
                            withAnimation(.smooth(duration: 0.25)) { lookedRight = latest.id.uuidString }
                        }
                        .buttonStyle(.bordered).accessibilityIdentifier("last-session-looks-right")
                    }
                    Button(line.action) { open(latest.id) }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(scheme == .dark ? TrainingHomeStyle.buttonInk : .white)
                        .accessibilityIdentifier("last-session-open")
                }
                .font(.subheadline.weight(.semibold))
                .tint(TrainingHomeStyle.accent(scheme))
            }
            .padding(16)
            .background(LeaderboardStyle.card(scheme), in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(LeaderboardStyle.line(scheme)) }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("leaderboard-last-session")
        }
    }

    private struct Line { let title: LocalizedStringKey; let detail: LocalizedStringKey; let action: LocalizedStringKey; var asks = false }

    private func line(for item: HistorySession) -> Line? {
        let streak = item.rankedProposal?.count ?? 0
        if review.uploadingSession == item.id || review.isQueued(item.id) {
            return Line(title: "Your touch check is on its way", detail: review.waitingForConnection
                        ? "It sends by itself when you’re back online." : "Sending short clips for review.", action: "View")
        }
        if let attempt = review.attempt(for: item.id) {
            switch attempt.status {
            case .pending: return Line(title: "Your touches are being checked",
                detail: "You asked for \(attempt.proposedCount). Your streak of \(streak) counts until then.", action: "View")
            case .approved: return Line(title: "Confirmed · \(attempt.reviewedCount ?? attempt.proposedCount)",
                detail: "Your last session’s streak was updated after review.", action: "View")
            case .rejected: return Line(title: "Not confirmed",
                detail: "Your last session’s streak stays at \(streak).", action: "View")
            case .uploading: return Line(title: "Your touch check isn’t sent yet",
                detail: "Open it to resume sending.", action: "Resume")
            case .withdrawn: return nil
            }
        }
        guard lookedRight != item.id.uuidString, let correction = LeaderboardCorrection(item: item),
              !correction.leftOut.isEmpty else { return nil }
        let leftOut = correction.leftOut.count
        return Line(title: "Last session · best streak \(streak)",
                    detail: "\(leftOut) touches the counter wasn’t sure of inside your streak. If they were valid, send them for a check.",
                    action: "Check touches", asks: true)
    }
}

/// Asks once whether to show the player on the leaderboard.
struct LeaderboardJoinCard: View {
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.colorScheme) private var scheme
    /// The account last asked, so the question is asked only once.
    @AppStorage("kicklab.leaderboard.askedToJoin") private var asked = ""
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        if let profile = player.profile, let id = player.userID, profile.id == id,
           !profile.leaderboardVisible, asked != id.uuidString {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LeaderboardBall(size: 30)
                    Text("Join the leaderboard?").font(.headline)
                }
                Text("Your best recorded streak appears after syncing. Other players see your name, \(profile.displayName), country, photo and streak stats. You can hide your entry any time in Profile.")
                    .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Not now") { withAnimation(.smooth(duration: 0.25)) { asked = id.uuidString } }
                        .buttonStyle(.bordered).accessibilityIdentifier("leaderboard-join-later")
                    Button { join(profile) } label: {
                        Text(saving ? "Joining…" : "Show me").frame(minWidth: 90)
                            .foregroundStyle(scheme == .dark ? TrainingHomeStyle.buttonInk : .white)
                    }
                    .buttonStyle(.borderedProminent).disabled(saving)
                    .accessibilityIdentifier("leaderboard-join")
                }
                .font(.subheadline.weight(.semibold))
                .tint(TrainingHomeStyle.accent(scheme))
                if failed {
                    Text("Couldn’t update your profile. Check your connection and try again.").font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(LeaderboardStyle.card(scheme), in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(LeaderboardStyle.lime.opacity(0.7), lineWidth: 1.5) }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("leaderboard-join-card")
        }
    }

    private func join(_ profile: PlayerProfile) {
        saving = true; failed = false
        Task {
            do {
                try await player.updateProfile(name: profile.displayName, country: profile.countryCode, visible: true)
                asked = profile.id.uuidString
            } catch { failed = true }
            saving = false
        }
    }
}
