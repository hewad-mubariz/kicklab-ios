import SwiftUI

/// Each destination shares the same surface, typography and spacing as Home.
private struct HubPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("KICKLAB / \(title.uppercased())")
                        .font(.system(size: 10, weight: .bold)).tracking(2)
                    Text(title).font(.system(size: 34, weight: .black).width(.condensed))
                    Text(subtitle).font(.subheadline)
                        .foregroundStyle(HomeSurface.mutedInk(scheme))
                }
                .padding(.top, 15)
                content
            }
            .foregroundStyle(HomeSurface.ink(scheme))
            .frame(maxWidth: 480)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }
}

struct TrainingHubView: View {
    let modules: [TrainingModule]
    let onSelect: (TrainingModule) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HubPage(title: "Train", subtitle: "Small touches. Big progress.") {
            VStack(alignment: .leading, spacing: 12) {
                Image("card-juggling")
                    .resizable().scaledToFill().frame(height: 185).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text("Juggling").font(.title2.bold())
                    Spacer()
                    Label("READY TO PLAY", systemImage: "circle.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(HomeSurface.green(scheme))
                }
                Text("Find your rhythm. Keep the ball up and make every touch count.")
                    .font(.subheadline)
                HubAction(title: "Start juggling", symbol: "arrow.right") {
                    if let juggling = modules.first(where: { $0.destination == .juggling }) { onSelect(juggling) }
                }
            }
            .padding(12).modifier(HomePanel())

            Text("MORE WAYS TO PLAY").font(.system(size: 11, weight: .bold)).tracking(1.5)
            VStack(spacing: 0) {
                ForEach(modules.filter { [.targetShoot, .powerShot, .freeKick, .penalties].contains($0.destination) }) { module in
                    Button { onSelect(module) } label: {
                        HStack(spacing: 12) {
                            Image(module.imageName).resizable().scaledToFill()
                                .frame(width: 65, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(module.title).font(.headline)
                                Text(module.destination == .powerShot ? module.subtitle : "Coming soon")
                                    .font(.caption).foregroundStyle(HomeSurface.mutedInk(scheme))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(HomePressStyle())
                    .accessibilityIdentifier("train-module-\(module.id)")
                    if module.destination != .penalties { Divider().padding(.horizontal, 12) }
                }
            }
            .modifier(HomePanel())
        }
    }
}

struct ProgressHubView: View {
    let milestone: Milestone
    let onTrain: () -> Void

    var body: some View {
        HubPage(title: "Progress", subtitle: "A little better. Every session.") {
            VStack(alignment: .leading, spacing: 16) {
                Label("YOUR NEXT GOAL", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .bold)).tracking(1)
                Text("50 touches.\nOne great juggle.")
                    .font(.system(size: 30, weight: .bold).width(.condensed))
                Text("Build control, find your rhythm, and see how far you can go.")
                    .font(.subheadline)
                HubAction(title: "Train toward this goal", symbol: "bolt.fill", action: onTrain)
            }
            .padding(20).modifier(HomePanel())
            MilestoneCardView(milestone: milestone, action: onTrain)
            Label("The home streak and milestone currently show sample progress. Session history is coming soon.", systemImage: "info.circle")
                .font(.footnote).padding(16).modifier(HomePanel())
        }
    }
}

struct ChallengesHubView: View {
    let milestone: Milestone
    let onTrain: () -> Void

    var body: some View {
        HubPage(title: "Challenges", subtitle: "Give your next session a little purpose.") {
            VStack(spacing: 14) {
                Image("icon-challenges").resizable().scaledToFit().frame(height: 110)
                Text("THE 50-TOUCH CHALLENGE")
                    .font(.system(size: 11, weight: .bold)).tracking(1.5)
                Text("Keep it going.").font(.system(size: 30, weight: .black).width(.condensed))
                Text("Aim for \(milestone.goal) touches in a single juggle. All you need is a ball and a little determination.")
                    .font(.subheadline).multilineTextAlignment(.center)
                HubAction(title: "Give it a try", symbol: "arrow.right", action: onTrain)
            }
            .padding(20).modifier(HomePanel())
            Label("Community challenges and tournaments are coming soon.", systemImage: "person.2")
                .font(.subheadline).padding(18).modifier(HomePanel())
        }
    }
}

struct ProfileHubView: View {
    let snapshot: HomeSnapshot
    @Binding var appearance: String

    var body: some View {
        HubPage(title: "Profile", subtitle: "Your game. Your way.") {
            HStack(spacing: 15) {
                Image("avatar-player").resizable().scaledToFill()
                    .frame(width: 58, height: 58).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.displayName).font(.title2.bold())
                    Text("Keep showing up.").font(.subheadline)
                }
                Spacer()
            }
            .padding(18).modifier(HomePanel())
            VStack(alignment: .leading, spacing: 14) {
                Label("Appearance", systemImage: "circle.lefthalf.filled").font(.headline)
                Text("Same experience. Any time.").font(.subheadline)
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-picker")
            }
            .padding(18).modifier(HomePanel())
            VStack(alignment: .leading, spacing: 8) {
                Label("Made for your practice", systemImage: "soccerball").font(.headline)
                Text("Practice. Improve. Repeat.").font(.subheadline)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(HomePanel())
        }
    }
}

private struct HubAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol)
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(HomeSurface.forest)
            .padding(16)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(HomePressStyle())
    }
}

struct ModePreviewSheet: View {
    let module: TrainingModule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(module.imageName).resizable().scaledToFill()
                .frame(height: 115).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
            Text(module.title).font(.title.bold())
            Text("This training mode is coming soon. In the meantime, build your ball control with Juggling.")
                .font(.subheadline).multilineTextAlignment(.center)
            Button("Got it") { dismiss() }.buttonStyle(.borderedProminent).tint(HomeSurface.forest)
        }
        .padding(24)
    }
}

struct NotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge").font(.system(size: 36)).foregroundStyle(HomeSurface.dayGreen)
            Text("You're all caught up").font(.title2.bold())
            Text("Your next great session is waiting. Head to Train when you're ready.")
                .font(.subheadline).multilineTextAlignment(.center)
            Button("Back to the pitch") { dismiss() }
                .buttonStyle(.borderedProminent).tint(HomeSurface.forest)
        }
        .padding(30)
    }
}
