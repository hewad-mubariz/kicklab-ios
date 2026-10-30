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
                            Label(entry.isPreview ? "Sample streak" : entry.hasConfirmedTouchCheck ? "Checked streak" : "Best streak",
                                  systemImage: entry.hasConfirmedTouchCheck ? "checkmark.seal.fill" : "soccerball").font(.headline)
                            Text("Rank #\(entry.rank)").foregroundStyle(.secondary)
                        }
                    }
                    if let code = entry.countryCode, let country = ProfileCountry.named(code) {
                        LabeledContent("Country", value: "\(country.flag) \(country.name)")
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Streak stats").font(.title2.bold())
                        LabeledContent {
                            Text(entry.streakDurationLabel).monospacedDigit()
                        } label: {
                            Label("Duration", systemImage: "timer")
                        }
                        LabeledContent {
                            Text(entry.averageRhythmLabel).monospacedDigit()
                        } label: {
                            Label("Average rhythm", systemImage: "metronome")
                        }
                        Text(entry.isPreview ? "Sample duration and rhythm for this preview. They do not affect rank."
                             : "Rhythm is the counted touches per minute over this streak. Only the touch count determines rank.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 20))
                    if entry.isPreview {
                        Label("Temporary player · no account or recording is attached to this sample.", systemImage: "eye")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Label(entry.hasConfirmedTouchCheck ? "A reviewer confirmed touches the counter had left out. The clips are private to the player and the review team."
                              : "Counted automatically from a recorded session.", systemImage: entry.hasConfirmedTouchCheck ? "lock" : "bolt")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if entry.isYou {
                            if LeaderboardRules.touchChecks {
                                Text("Open Touch checks to see touches left out of your sessions, or the result of a check.").font(.subheadline)
                            }
                        } else if entry.hasConfirmedTouchCheck {
                            Button("Report this score", systemImage: "flag") { showsReport = true }
                                .disabled(review.owner == nil)
                            if review.owner == nil { Text("Sign in through Profile to report a score.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .navigationTitle(entry.isYou ? (entry.isPreview ? String(localized: "Your sample attempt", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "Your best streak", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) : entry.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("leaderboard-player-close")
            } }
            .sheet(isPresented: $showsReport) {
                if entry.hasConfirmedTouchCheck, let id = entry.attemptID {
                    LeaderboardFeedbackView(title: "Report this score", review: review) { await review.report(id, reason: $0) }
                }
            }
        }
    }
}
