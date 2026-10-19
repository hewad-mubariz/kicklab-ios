import SwiftUI

struct LeaderboardRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("PLAY FAIR. KEEP IT GOING.").font(.caption.weight(.bold)).tracking(1.3)
                            .foregroundStyle(TrainingHomeStyle.accent(scheme))
                        Text("Your best streak counts.").font(.largeTitle.bold())
                        Text("Every published score is reviewed.").foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                    group("THE STREAK") {
                        rule("What counts", "Feet, legs, knees/thighs, chest and head. Inside and outside feet both count. One distinct contact earns one point.", "soccerball")
                        Divider()
                        rule("What ends a streak", "Ground, hands, arms, a catch, a held stall or outside help. Start a new streak after an interruption.", "nosign", warning: true)
                    }
                    group("RECORD & REVIEW") {
                        rule("Keep it visible", "Use one size-5 football. Record in the app and keep the player, ball, contact areas and nearby ground in frame. An initial hand release earns no points.", "video")
                        Divider()
                        rule("Checked before ranking", "Your longest uninterrupted streak sets your score. Clear original video can correct missed detections. If continuity is unclear, only a supported segment can qualify.", "checkmark.seal")
                    }
                    Label("Spin and height describe your run. They do not add points.", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.subheadline).foregroundStyle(.secondary)
                    group("WEEKLY & ALL-TIME") {
                        rule("One best score per player", "The weekly board resets Monday at 00:00 UTC. Your complete upload’s server receipt time determines its week and breaks ties. A later review still belongs to the original submission week.", "calendar")
                        Text("Next reset: \(LeaderboardRules.nextReset().formatted(date: .abbreviated, time: .shortened)) · your time")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    group("SUBMISSION & PRIVACY") {
                        Text(LeaderboardRules.privacy).font(.subheadline)
                        Text("Submission publishes your chosen profile name, photo and approved score. Gallery imports and guest recordings remain personal. The beta allows three submissions per day and three awaiting review; processing after recording is equally eligible.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    group("CORRECTIONS & FAIR PLAY") {
                        Text("Open My submissions to see a decision, its reason and any relevant timestamp, or request one re-review. Report a published score from its detail view. Duplicate recordings and edited clips cannot qualify.")
                            .font(.subheadline)
                        Text("No prizes, paid score advantages or trick bonuses in this beta. Training remains available without joining.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Rules \(LeaderboardRules.version)").font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .navigationTitle("Leaderboard rules").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(TrainingHomeStyle.accent(scheme))
        .accessibilityIdentifier("leaderboard-rules")
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TrainingHomeStyle.line(scheme)))
        }
    }
    private func rule(_ title: String, _ text: String, _ symbol: String, warning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 28)
                .foregroundStyle(warning ? Color(red: 0.65, green: 0.22, blue: 0.12) : TrainingHomeStyle.accent(scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
