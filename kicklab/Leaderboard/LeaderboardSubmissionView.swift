import AVKit
import SwiftUI

struct LeaderboardSubmissionsView: View {
    @ObservedObject var review: LeaderboardReviewStore
    @ObservedObject var history: SessionHistoryStore
    var onRecord: (() -> Void)? = nil
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsSignIn = false
    @State private var showsRules = false
    var body: some View {
        NavigationStack {
            List {
                if review.owner == nil {
                    Section {
                        Text("Browse the rankings freely. Sign in before recording an attempt you want to submit.")
                        Button("Sign in") { showsSignIn = true }
                    }
                } else {
                    Section {
                        NavigationLink { LeaderboardRecordingPicker(review: review, history: history) } label: {
                            Label("Check a session’s touches", systemImage: "checklist")
                        }.accessibilityIdentifier("leaderboard-choose-recording")
                        if let onRecord { Button("Record a session", action: onRecord) }
                    } footer: { Text("Your best streak ranks by itself after each recorded session. Send touches the counter left out only if you think they were valid.") }
                    Section {
                        if review.isLoading && review.attempts.isEmpty { ProgressView("Loading submissions…") }
                        if !review.isLoading && review.attempts.isEmpty && review.queued.isEmpty {
                            Text("No touch checks yet.").foregroundStyle(.secondary)
                        }
                        ForEach(review.queued, id: \.sessionID) { entry in
                            NavigationLink {
                                LeaderboardCorrectionView(sessionID: entry.sessionID, review: review, history: history)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(review.uploadingSession == entry.sessionID ? "Sending…" : "Waiting to send").font(.headline)
                                        Spacer()
                                        Text("\(entry.proposal.count)").bold().monospacedDigit()
                                    }
                                    Text(review.waitingForConnection ? "Sends by itself when you’re back online" : "Sends by itself, no need to stay here")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("leaderboard-queued-\(entry.sessionID)")
                        }
                        ForEach(review.attempts.filter { !review.isQueued($0.sessionID) }) { attempt in
                            NavigationLink {
                                LeaderboardAttemptStatusView(attemptID: attempt.id, review: review, history: history)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(attempt.status.label).font(.headline)
                                        Spacer()
                                        Text("\(attempt.reviewedCount ?? attempt.proposedCount)").bold().monospacedDigit()
                                    }
                                    Text(attempt.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    if let report = attempt.touchReview {
                                        Text(report.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if attempt.hasPendingAppeal { Text("Re-review requested").font(.caption) }
                                }
                            }
                        }
                    } header: { Text("Touch checks") } footer: { Text("Showing your latest 100 checks.") }
                }
                if let error = review.errorMessage {
                    Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await review.refresh() } } }
                }
                Section { Button("Leaderboard rules") { showsRules = true } }
            }
            .navigationTitle("Touch checks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await review.refresh(); await history.refresh() }
            .sheet(isPresented: $showsRules) { LeaderboardRulesView() }
            .fullScreenCover(isPresented: $showsSignIn) {
                SignInView(presentation: .profile) { showsSignIn = false }
            }
            .onChange(of: account.user?.id) { _, value in if value != nil { showsSignIn = false } }
            .task(id: review.owner) { await review.refresh(); await history.refresh() }
        }
        .id(review.owner)
        .accessibilityIdentifier("leaderboard-submissions")
    }
}

private struct LeaderboardRecordingPicker: View {
    @ObservedObject var review: LeaderboardReviewStore
    @ObservedObject var history: SessionHistoryStore
    private var eligible: [HistorySession] {
        history.items.filter { $0.ownerID == review.owner && $0.ownerID != nil && $0.source == .recording }
    }
    var body: some View {
        List {
            Section {
                ForEach(eligible) { item in
                    NavigationLink {
                        LeaderboardCorrectionView(sessionID: item.id, review: review, history: history)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.completedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(detail(item)).font(.subheadline).foregroundStyle(.secondary)
                            if history.replayURL(for: item) == nil { Text("Recording not on this phone").font(.caption) }
                        }
                    }
                }
                if eligible.isEmpty { Text("Record a juggling session while signed in, then return here.") }
                if history.hasMore { Button("Load more recordings") { Task { await history.loadMore() } } }
            } footer: { Text("Each session ranks by its best streak. Open one to see the touches the counter left out.") }
        }.navigationTitle("Choose a session").navigationBarTitleDisplayMode(.inline)
    }
    private func detail(_ item: HistorySession) -> String {
        let streak = item.rankedProposal.map { "Best streak \($0.count)" } ?? "\(item.touches) touches"
        let askable = LeaderboardCorrection(item: item)?.askable.count ?? 0
        return askable == 0 ? "\(item.durationLabel) · \(streak)" : "\(item.durationLabel) · \(streak) · \(askable) to check"
    }
}

struct LeaderboardAttemptStatusView: View {
    let attemptID: UUID
    @ObservedObject var review: LeaderboardReviewStore
    @ObservedObject var history: SessionHistoryStore
    @State private var confirmsWithdrawal = false
    @State private var showsAppeal = false
    @State private var original: URL?
    private var attempt: LeaderboardAttempt? { review.attempts.first { $0.id == attemptID } }
    private var localOriginal: URL? {
        guard let attempt, let item = history.items.first(where: { $0.id == attempt.sessionID && $0.ownerID == review.owner }) else { return nil }
        return history.replayURL(for: item)
    }
    var body: some View {
        List {
            if let attempt {
                Section {
                    Label(attempt.status.label, systemImage: attempt.status == .approved ? "checkmark.seal.fill" : "clock")
                    LabeledContent("Asked for", value: "\(attempt.proposedCount) touches")
                    if let count = attempt.reviewedCount { LabeledContent("Reviewed streak", value: "\(count) touches") }
                    if let first = attempt.reviewedStartMS, let last = attempt.reviewedEndMS {
                        LabeledContent("Reviewed segment") {
                            Text("\(Double(first)/1000, specifier: "%.1f")–\(Double(last)/1000, specifier: "%.1f") s")
                        }
                    }
                    if let reason = attempt.reviewReason { Text(reason) }
                    if let time = attempt.reasonTimeMS { Text("Review timestamp: \(Double(time)/1000, specifier: "%.1f") s").font(.footnote) }
                    if attempt.hasPendingAppeal { Text("Re-review requested. Your previous decision stays visible until reviewed again.").font(.footnote) }
                    else if attempt.appealAt != nil { Text("Your re-review is complete.").font(.footnote) }
                }
                LeaderboardTouchReviewSection(report: attempt.touchReview, videoURL: localOriginal ?? original)
                if let original { Section { LeaderboardOriginalPlayer(url: original).frame(height: 260) } }
                Section {
                    if attempt.status == .uploading {
                        NavigationLink("Resume sending") { LeaderboardCorrectionView(sessionID: attempt.sessionID, review: review, history: history) }
                    } else if attempt.hasPrivateVideo {
                        Button("Watch submitted clips") {
                            Task {
                                do { original = try await review.videoURL(for: attempt) }
                                catch { review.errorMessage = error.localizedDescription }
                            }
                        }
                    }
                    if [.approved,.rejected].contains(attempt.status), attempt.appealAt == nil, attempt.hasPrivateVideo {
                        Button("Request a score review") { showsAppeal = true }
                    }
                    if attempt.status != .withdrawn { Button("Withdraw check", role: .destructive) { confirmsWithdrawal = true } }
                }
                if let error = review.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Touch check").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Withdraw this check?", isPresented: $confirmsWithdrawal, titleVisibility: .visible) {
            Button("Withdraw and remove video", role: .destructive) {
                if let attempt { original = nil; Task { await review.withdraw(attempt) } }
            }
        } message: { Text("Any correction it made is removed immediately and your device-counted streak counts again. The clips are queued for deletion within 24 hours. Your recording stays on your phone.") }
        .sheet(isPresented: $showsAppeal) {
            if let attempt {
                LeaderboardFeedbackView(title: "Request a score review", review: review) { text in await review.appeal(attempt, reason: text) }
            }
        }
        .onChange(of: review.owner) { _, _ in original = nil }
    }
}

struct LeaderboardFeedbackView: View {
    let title: String
    @ObservedObject var review: LeaderboardReviewStore
    let send: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section { TextEditor(text: $text).frame(minHeight: 160) } footer: {
                    Text("Explain the issue and include the video timestamp if you know it. 10–1,000 characters.")
                }
                if let error = review.errorMessage { Text(error).foregroundStyle(.red) }
                Button(busy ? "Sending…" : "Send for review") {
                    busy = true
                    Task { let success = await send(text.trimmingCharacters(in: .whitespacesAndNewlines)); busy = false; if success { dismiss() } }
                }.disabled(busy || !(10...1000).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).count))
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
        }
    }
}

struct LeaderboardOriginalPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) { player?.pause(); player = AVPlayer(url: url) }
            .onDisappear { player?.pause(); player = nil }
            .onChange(of: phase) { _, value in if value != .active { player?.pause() } }
    }
}
