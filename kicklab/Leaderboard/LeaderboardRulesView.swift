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
                        rule("For example", "You make 30 touches and the counter isn’t sure of 3 of them, so that run counts 27. Then you stop the ball with your hand and juggle 20 more. Your score is 27, your longest run, not the 50 in all.", "number")
                    }
                    group("HOW IT’S COUNTED") {
                        rule("Automatic", "Each session recorded in the app while signed in ranks by its longest streak as soon as it syncs. There is nothing to submit.", "bolt")
                        Divider()
                        rule("Touches the counter isn’t sure of", "When hands are hidden, the body is unclear or the ball is lost for a moment, the counter leaves that touch out. It doesn’t count, and it doesn’t end your streak either.", "questionmark.circle")
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
                        rule("You choose to appear", "You’re asked once before you join. Other players see your profile name, photo and best streak, and you can hide them any time in Profile. Gallery imports and guest sessions never rank.", "person.crop.circle.badge.checkmark")
                        if LeaderboardRules.touchChecks {
                            Divider()
                            Text(LeaderboardRules.privacy).font(.subheadline).foregroundStyle(.secondary)
                            Text("The beta allows three checks per day and three waiting for review.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Divider()
                            Text("Your recordings stay on your phone. Only each session’s touch count, best streak, length and date reach your account.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    group("FAIR PLAY") {
                        Text(LeaderboardRules.touchChecks ? "A reviewer can correct or remove any score. Duplicate recordings and edited clips cannot qualify."
                             : "Scores that break these rules or look impossible can be removed from the board.")
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
