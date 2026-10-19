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
                            Label("Submit an attempt", systemImage: "video.badge.plus")
                        }.accessibilityIdentifier("leaderboard-choose-recording")
                        if let onRecord { Button("Record a new attempt", action: onRecord) }
                    } footer: { Text("Original recordings only. Your training total is never submitted automatically.") }
                    Section {
                        if review.isLoading && review.attempts.isEmpty { ProgressView("Loading submissions…") }
                        if !review.isLoading && review.attempts.isEmpty { Text("No submissions yet.").foregroundStyle(.secondary) }
                        ForEach(review.attempts) { attempt in
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
                                    if attempt.hasPendingAppeal { Text("Re-review requested").font(.caption) }
                                }
                            }
                        }
                    } header: { Text("My submissions") } footer: { Text("Showing your latest 100 submissions.") }
                }
                if let error = review.errorMessage {
                    Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await review.refresh() } } }
                }
                Section { Button("Leaderboard rules") { showsRules = true } }
            }
            .navigationTitle("My submissions").navigationBarTitleDisplayMode(.inline)
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
                        LeaderboardSubmissionView(sessionID: item.id, review: review, history: history)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.completedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(item.durationLabel) · \(item.touches) total touches").font(.subheadline).foregroundStyle(.secondary)
                            if history.replayURL(for: item) == nil { Text("Original not on this phone").font(.caption) }
                        }
                    }
                }
                if eligible.isEmpty { Text("Record a juggling session while signed in, then return here.") }
                if history.hasMore { Button("Load more recordings") { Task { await history.loadMore() } } }
            } footer: { Text("Select one continuous streak from a recording. Reviewers verify the original video before any score is published.") }
        }.navigationTitle("Choose a recording").navigationBarTitleDisplayMode(.inline)
    }
}

struct LeaderboardSubmissionView: View {
    let sessionID: UUID
    @ObservedObject var review: LeaderboardReviewStore
    @ObservedObject var history: SessionHistoryStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerStore
    @State private var count = ""
    @State private var start = "0"
    @State private var end = ""
    @State private var confirmed = false
    @State private var showsRules = false
    @State private var configured = false
    private var item: HistorySession? { history.items.first { $0.id == sessionID && $0.ownerID == review.owner } }
    private var attempt: LeaderboardAttempt? { review.attempt(for: sessionID) }
    private var busy: Bool { review.uploadingSession != nil }
    private var proposal: RankedStreakProposal? {
        guard let count = Int(count), let first = Double(start.replacingOccurrences(of: ",", with: ".")),
              let last = Double(end.replacingOccurrences(of: ",", with: ".")), first.isFinite, last.isFinite,
              first >= 0, last <= 86400, last > first else { return nil }
        return .init(count: count, startMS: Int((first*1000).rounded()), endMS: Int((last*1000).rounded()))
    }
    var body: some View {
        Form {
            if let attempt, attempt.status != .uploading {
                Section {
                    Label(attempt.status.label, systemImage: attempt.status == .approved ? "checkmark.seal" : "clock")
                    Text("This recording already has a submission. Follow it in My submissions.")
                    NavigationLink("View submission") {
                        LeaderboardAttemptStatusView(attemptID: attempt.id, review: review, history: history)
                    }
                }
            } else if let item, item.source == .recording, item.ownerID != nil, let video = history.replayURL(for: item) {
                Section {
                    LeaderboardOriginalPlayer(url: video).frame(height: 240)
                    Text("Original recording · \(item.durationLabel)").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Touches") { TextField("Count", text: $count).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    LabeledContent("Start · seconds") { TextField("0", text: $start).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    LabeledContent("End · seconds") { TextField("End", text: $end).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                } header: { Text("Proposed continuous streak") } footer: { Text("Check the original and choose one uninterrupted run. This is a proposal, not a reviewed score. A missed detection can be corrected during review.") }
                .disabled(busy || attempt != nil)
                Section("Before you submit") {
                    Button("Read leaderboard rules") { showsRules = true }
                    Toggle("I used a size-5 football and agree to the rules and private video review.", isOn: $confirmed)
                    Text("If approved, publish my profile name, photo and reviewed score on the leaderboard.").font(.footnote)
                    Text(LeaderboardRules.privacy).font(.footnote).foregroundStyle(.secondary)
                }.disabled(busy)
                Section {
                    if item.syncState != .synced {
                        Text("Your session is still syncing to your account. Please wait before submitting.")
                    }
                    if review.uploadingSession == sessionID {
                        ProgressView(value: review.progress) { Text(review.phase) }
                        Text("Keep the app open during upload. You can pause and resume from My submissions.").font(.caption)
                        Button("Pause upload") { review.pauseUpload() }
                    } else {
                        Button(attempt == nil ? "Submit original for review" : "Resume upload") {
                            guard let proposal = attempt?.proposal ?? proposal else { return }
                            review.submit(item: item, proposal: proposal, video: video)
                        }
                        .disabled(!confirmed || busy || item.syncState != .synced || proposal?.isValid(durationMS: item.durationMS) != true)
                        .accessibilityIdentifier("leaderboard-submit-original")
                    }
                    if let error = review.errorMessage { Text(error).foregroundStyle(.red) }
                }
            } else {
                Text(LeaderboardFailure.originalRequired.localizedDescription)
            }
        }
        .navigationTitle("Submit an attempt").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsRules) { LeaderboardRulesView() }
        .task { await review.refresh(); await history.refresh(); configureDraft() }
        .onChange(of: item, initial: true) { _, _ in configureDraft() }
        .onChange(of: attempt?.id) { _, _ in
            if attempt?.status == .uploading { configured = false; configureDraft() }
        }
        .onChange(of: attempt?.status) { _, status in
            if status == .pending { Task { await player.refresh() } }
        }
        .onChange(of: review.owner) { _, _ in dismiss() }
        .accessibilityIdentifier("leaderboard-submission-editor")
    }
    private func configureDraft() {
        guard !configured, let item else { return }; configured = true
        let draft = attempt?.proposal ?? item.rankedProposal
        count = draft.map { String($0.count) } ?? ""
        start = draft.map { String(format: "%.3f", Double($0.startMS)/1000) } ?? "0"
        end = String(format: "%.3f", Double(draft?.endMS ?? item.durationMS)/1000)
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
    var body: some View {
        List {
            if let attempt {
                Section {
                    Label(attempt.status.label, systemImage: attempt.status == .approved ? "checkmark.seal.fill" : "clock")
                    LabeledContent("Proposed", value: "\(attempt.proposedCount) touches")
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
                if let original { Section { LeaderboardOriginalPlayer(url: original).frame(height: 260) } }
                Section {
                    if attempt.status == .uploading {
                        NavigationLink("Resume upload") { LeaderboardSubmissionView(sessionID: attempt.sessionID, review: review, history: history) }
                    } else if attempt.hasPrivateVideo {
                        Button("Watch private original") {
                            Task {
                                do { original = try await review.videoURL(for: attempt) }
                                catch { review.errorMessage = error.localizedDescription }
                            }
                        }
                    }
                    if [.approved,.rejected].contains(attempt.status), attempt.appealAt == nil, attempt.hasPrivateVideo {
                        Button("Request a score review") { showsAppeal = true }
                    }
                    if attempt.status != .withdrawn { Button("Withdraw attempt", role: .destructive) { confirmsWithdrawal = true } }
                }
                if let error = review.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Submission details").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Withdraw this attempt?", isPresented: $confirmsWithdrawal, titleVisibility: .visible) {
            Button("Withdraw and remove video", role: .destructive) {
                if let attempt { original = nil; Task { await review.withdraw(attempt) } }
            }
        } message: { Text("The score disappears immediately. The private original is queued for deletion within 24 hours. Your local recording stays on your phone.") }
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
