import SwiftUI

struct LeaderboardPlayerDetailView: View {
    let entry: LeaderboardEntry
    @ObservedObject var review: LeaderboardReviewStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showsReport = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 20) {
                        LeaderboardMedallion(entry: entry, size: 88, ring: TrainingHomeStyle.accent(scheme))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.touches.formatted()).font(TrainingHomeStyle.display(80, relativeTo: .largeTitle)).monospacedDigit()
                            Label("Reviewed streak", systemImage: "checkmark.seal.fill").font(.headline)
                            Text("Rank #\(entry.rank)").foregroundStyle(.secondary)
                        }
                    }
                    if let code = entry.countryCode, let country = ProfileCountry.named(code) {
                        LabeledContent("Country", value: "\(country.flag) \(country.name)")
                    }
                    if let duration = entry.streakDurationMS {
                        LabeledContent("Streak duration", value: String(format: "%d:%02d", duration/60000, duration/1000 % 60))
                        LabeledContent("Average rhythm", value: duration > 0 ? String(format: "%.0f touches/min", Double(entry.touches)*60000/Double(duration)) : "Unavailable")
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("Juggling style").font(.title2.bold()); Spacer(); Text("Estimated").font(.caption).foregroundStyle(.secondary) }
                        Label { Text("Backspin · Unavailable") } icon: { LeaderboardSpinIcon() }
                        Label("Typical height · Unavailable", systemImage: "arrow.up.and.down")
                        Text("Style measurements appear when supported by reliable evidence. They do not affect rank.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 20))
                    Label("The original recording is private to its owner and the review team.", systemImage: "lock")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if entry.isYou {
                        Text("Open My submissions to watch your original, see the review or request a correction.").font(.subheadline)
                    } else if entry.attemptID != nil {
                        Button("Report this score", systemImage: "flag") { showsReport = true }
                            .disabled(review.owner == nil)
                        if review.owner == nil { Text("Sign in through Profile to report a score.").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .navigationTitle(entry.isYou ? "Your reviewed attempt" : entry.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("leaderboard-player-close")
            } }
            .sheet(isPresented: $showsReport) {
                if let id = entry.attemptID {
                    LeaderboardFeedbackView(title: "Report this score", review: review) { await review.report(id, reason: $0) }
                }
            }
        }
    }
}

struct LeaderboardSpinIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").font(.system(size: 21))
            Image(systemName: "soccerball").font(.system(size: 10))
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}
