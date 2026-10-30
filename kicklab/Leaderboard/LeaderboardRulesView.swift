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
                        Text(LeaderboardRules.touchChecks ? "Counted for you after every recorded session. Checked by a person only when you ask."
                             : "Counted for you after every recorded session.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                    group("THE STREAK") {
                        rule("What counts", "Feet, legs, knees/thighs, chest and head. Inside and outside feet both count. One distinct contact earns one point. Your streak starts at your first touch after you drop the ball from your hands.", "soccerball")
                        Divider()
                        rule("What ends a streak", "The ground, a hand or arm, a catch or a held stall. Touches after a stop start a new streak, and only your longest one ranks, never your session total.", "nosign", warning: true)
                        Divider()
                        rule("For example", "The app counts runs of 10, 50 and 30 touches, separated by detected stops. Your session total is 90, and your leaderboard score is 50: your longest streak.", "number")
                    }
                    group("HOW IT’S COUNTED") {
                        rule("Automatic", "After you join the leaderboard, sessions recorded in the app while signed in rank by their longest counted streak once synced. There is nothing to submit.", "bolt")
                        Divider()
                        rule("Touches the counter isn’t sure of", "A possible touch that the counter cannot confirm is left out. Uncertain visibility alone does not end your streak.", "questionmark.circle")
                        Text("Automatic counts can miss touches or interruptions. Keep the ball and your body clearly visible.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if LeaderboardRules.touchChecks { checkRules }
                    }
                    Label("Duration and rhythm describe your streak. They do not add points.", systemImage: "metronome")
                        .font(.subheadline).foregroundStyle(.secondary)
                    group("WEEKLY & ALL-TIME") {
                        rule("One best streak per player", LeaderboardRules.touchChecks
                             ? "The weekly board resets Monday at 00:00 UTC. A session counts in the week you recorded it, even if a check finishes later. Ties go to the earlier session."
                             : "The weekly board resets Monday at 00:00 UTC. A session counts in the week you recorded it. Ties go to the earlier session.", "calendar")
                        Text("Next reset: \(LeaderboardRules.nextReset().formatted(date: .abbreviated, time: .shortened)) · your time")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    group("RECORDING & PRIVACY") {
                        rule("Keep it visible", "Use one size-5 football. Keep yourself, the ball and the ground near you in frame. An initial hand release earns no points.", "video")
                        Divider()
                        rule("You choose to appear", "Joining is optional. Other players see your name, country, photo and best streak with its duration and rhythm. You can hide your entry any time in Profile. Gallery imports and guest sessions never rank.", "person.crop.circle.badge.checkmark")
                        if LeaderboardRules.touchChecks {
                            Divider()
                            Text(LeaderboardRules.privacy).font(.subheadline).foregroundStyle(.secondary)
                            Text("The beta allows three checks per day and three waiting for review.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Divider()
                            Text("Your recordings stay on your phone. Session results and basic session details sync to your account.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    group("FAIR PLAY") {
                        Text(LeaderboardRules.touchChecks ? "A reviewer can correct or remove any score. Duplicate recordings and edited clips cannot qualify."
                             : "Scores that break these rules or look impossible can be removed from the board.")
                            .font(.subheadline)
                        Text("There are no prizes, paid score advantages or trick bonuses. You can train without joining.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .navigationTitle("Leaderboard rules").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(TrainingHomeStyle.accent(scheme))
        .accessibilityIdentifier("leaderboard-rules")
    }
    /// Sending unsure touches for review, once touch checks are on.
    @ViewBuilder private var checkRules: some View {
        Divider()
        rule("Ask for a check", "After a session, open your streak to see the touches inside it that the counter wasn’t sure of. If some were valid, send them. A reviewer watches short clips of just those moments and, if they confirm them, your streak goes up. Clear hand touches, catches and bounces aren’t offered: they always end a streak.", "checkmark.seal")
        Divider()
        rule("Still disagree?", "Open the check in Touch checks and ask for one re-review.", "arrow.uturn.backward.circle")
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TrainingHomeStyle.line(scheme)))
        }
    }
    private func rule(_ title: LocalizedStringKey, _ text: LocalizedStringKey, _ symbol: String, warning: Bool = false) -> some View {
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
