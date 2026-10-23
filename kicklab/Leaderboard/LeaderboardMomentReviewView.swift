import AVKit
import SwiftUI

struct LeaderboardTouchReviewSection: View {
    let report: LeaderboardTouchReview?
    let videoURL: URL?
    var body: some View {
        Section {
            if let report {
                Label(report.summary, systemImage: report.moments.isEmpty ? "video" : "viewfinder")
                    .accessibilityIdentifier("leaderboard-moment-summary")
                if !report.complete {
                    Text("Moment details are incomplete. Review the full recording before proposing a streak.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !report.moments.isEmpty, let videoURL {
                    NavigationLink("Review moments") {
                        LeaderboardMomentReviewView(report: report, url: videoURL)
                    }.accessibilityIdentifier("leaderboard-review-moments")
                } else if !report.moments.isEmpty {
                    Text("Open the private original below to replay these moments.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Moment details are not available for this recording. You can still submit; the first and last seconds of your streak are sent for review.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Moments to review") } footer: {
            Text("Flags identify moments to check, not cheating. A reviewer decides whether they count.")
        }
    }
}

struct LeaderboardMomentReviewView: View {
    let report: LeaderboardTouchReview
    let url: URL
    @State private var selected: LeaderboardReviewMoment?
    @State private var player: AVPlayer?
    @State private var showsOriginal = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        List {
            Section {
                VideoPlayer(player: player).frame(height: 270)
                    .accessibilityIdentifier("leaderboard-moment-player")
                if let selected {
                    Text("\(selected.timestamp) · \(selected.kind.title)").font(.headline)
                    Text(selected.kind.explanation).font(.subheadline).foregroundStyle(.secondary)
                    Button("Play this moment") { play(selected) }
                        .accessibilityIdentifier("leaderboard-play-moment")
                }
                Button("Watch full recording") { player?.pause(); showsOriginal = true }
            } footer: { Text("Each preview includes footage before and after the flagged moment. Check the full recording for continuity.") }
            Section(report.summary) {
                ForEach(report.moments) { moment in
                    Button { selected = moment; play(moment) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: moment.kind.breaksStreak ? "pause.circle" : "questionmark.circle")
                                .foregroundStyle(moment.kind.breaksStreak ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(moment.kind.title).foregroundStyle(.primary)
                                Text("\(moment.timestamp) · \(moment.kind.breaksStreak ? "Suggested streak split" : "Needs a closer look")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selected?.id == moment.id { Image(systemName: "play.circle.fill") }
                        }
                    }.accessibilityIdentifier("leaderboard-moment-\(moment.id)")
                }
            }
        }
        .navigationTitle("Review moments").navigationBarTitleDisplayMode(.inline)
        .task(id: url) {
            player?.pause(); player = AVPlayer(url: url)
            selected = selected ?? report.moments.first
            if let selected {
                player?.seek(to: CMTime(value: Int64(selected.timeMS), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: phase) { _, value in if value != .active { player?.pause() } }
        .sheet(isPresented: $showsOriginal) {
            NavigationStack {
                LeaderboardOriginalPlayer(url: url)
                    .navigationTitle("Original recording").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsOriginal = false } } }
            }
        }
    }

    private func play(_ moment: LeaderboardReviewMoment) {
        guard let player else { return }
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = CMTime(value: Int64(moment.clipEndMS), timescale: 1000)
        player.seek(to: CMTime(value: Int64(moment.clipStartMS), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

/// A quiet entry point after Stop; normal playback, editing and saving stay available.
struct LeaderboardReplayReviewCard: View {
    let sessionID: UUID
    @ObservedObject var history: SessionHistoryStore
    let open: () -> Void
    var body: some View {
        if let item = history.items.first(where: { $0.id == sessionID && $0.ownerID == history.ownerID }),
           item.ownerID != nil, item.source == .recording {
            let askable = LeaderboardCorrection(item: item)?.leftOut.count ?? 0
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "trophy")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.rankedProposal.map { "Best streak \($0.count)" } ?? "Leaderboard streak")
                            .font(.subheadline.weight(.semibold))
                        Text(askable == 0 ? "Counts on the leaderboard by itself"
                             : "\(askable) \(askable == 1 ? "touch" : "touches") to check · counts by itself")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .padding(12).background(.black.opacity(0.6), in: .rect(cornerRadius: 16))
            }.buttonStyle(.plain).foregroundStyle(.white)
                .accessibilityIdentifier("replay-leaderboard-review-card")
        }
    }
}
