import SwiftUI

struct HomeView: View {
    let personalBest: Int
    let onJuggling: () -> Void
    let onPowerShot: () -> Void
    let onImport: () -> Void
    let onProfile: () -> Void
    let onSetupGuide: () -> Void
    var onLeaderboard: (() -> Void)? = nil
    var onHistory: (() -> Void)? = nil
    /// Lets the leaderboard zoom out of its button.
    var leaderboardZoom: Namespace.ID? = nil
    var profileZoom: Namespace.ID? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 26)
                trainingHeading.padding(.bottom, 18)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                         count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    TrainingHomeCard(image: "home-juggling", category: "01 / CONTROL",
                                     title: "JUGGLING", subtitle: "Count touches.\nFind your rhythm.",
                                     actionLabel: "Start session", primary: true, action: onJuggling)
                        .accessibilityIdentifier("module-juggling")
                    TrainingHomeCard(image: "home-power-shot", category: "02 / CREATE",
                                     title: "BALL DISTANCE", subtitle: "Track a ground roll.\nMake it yours with effects.",
                                     actionLabel: "Record + effects", primary: false, action: onPowerShot)
                        .accessibilityIdentifier("module-power-shot")
                }
                personalBestRow.padding(.vertical, 22)
                if let onHistory {
                    Button(action: onHistory) {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title3).foregroundStyle(TrainingHomeStyle.accent(scheme))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Session history").font(.subheadline.weight(.semibold))
                                Text("Your touches, time and replays").font(.caption)
                                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.subheadline)
                        }
                        .padding(16).frame(maxWidth: .infinity, minHeight: 62)
                        .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(TrainingHomeStyle.line(scheme)))
                        .contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("home-session-history")
                    .padding(.bottom, 22)
                }
                Rectangle().fill(TrainingHomeStyle.line(scheme)).frame(height: 1)
                importButton.padding(.top, 22)
                Button(action: onSetupGuide) {
                    Label("How to set up your camera", systemImage: "viewfinder")
                        .font(.caption)
                        .foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-setup-guide")
                .padding(.top, 4)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.background(scheme).ignoresSafeArea())
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .accessibilityIdentifier("home-screen")
    }

    private var header: some View {
        HStack {
            Text("Juggle Dude")
                .font(TrainingHomeStyle.display(30, relativeTo: .title2))
                .tracking(1.5)
                .accessibilityLabel("Juggle Dude")
            Spacer()
            if let onLeaderboard {
                HomeLeaderboardButton(action: onLeaderboard, zoom: leaderboardZoom)
            }
            HomeProfileButton(action: onProfile, zoom: profileZoom)
        }
    }

    private var trainingHeading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                trainingTitle
                Spacer(minLength: 12)
                availability
            }
            VStack(alignment: .leading, spacing: 8) {
                trainingTitle
                availability
            }
        }
    }

    private var trainingTitle: some View {
        Text("YOUR TRAINING")
            .font(TrainingHomeStyle.display(34, relativeTo: .title))
            .accessibilityAddTraits(.isHeader)
    }

    private var availability: some View {
        HStack(spacing: 5) {
            Circle().fill(TrainingHomeStyle.accent(scheme)).frame(width: 5, height: 5)
            Text("02 AVAILABLE").font(.caption2.weight(.semibold)).tracking(0.6)
        }
        .foregroundStyle(TrainingHomeStyle.muted(scheme))
        .fixedSize()
        .accessibilityLabel("2 training modes available")
    }

    private var personalBestRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Image(systemName: "trophy")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                .frame(width: 42, height: 42)
                .background(TrainingHomeStyle.accent(scheme).opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("JUGGLING PERSONAL BEST").font(.caption2.weight(.semibold)).tracking(0.5)
                Text(personalBest > 0 ? "A little better, every session." : "Your first record starts here.")
                    .font(.caption)
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
                Text(personalBest > 0 ? "\(personalBest)" : "—")
                    .font(TrainingHomeStyle.display(44, relativeTo: .largeTitle))
                    .monospacedDigit()
                Text("touches").font(.caption2).foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(personalBest > 0 ? "Juggling personal best, \(personalBest) touches" : "Juggling personal best. Your first record starts here.")
        .accessibilityIdentifier("home-personal-best")
    }

    private var importButton: some View {
        Button(action: onImport) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                Text("Import a juggling video").font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(minHeight: 54)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TrainingHomeStyle.line(scheme)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-import-video")
    }
}

private struct TrainingHomeCard: View {
    let image: String
    let category: String
    let title: String
    let subtitle: String
    let actionLabel: String
    let primary: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var imageHeight: CGFloat = 232

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    GeometryReader { geometry in
                        Image(image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    LinearGradient(stops: [.init(color: .black.opacity(0.24), location: 0),
                                           .init(color: .clear, location: 0.3),
                                           .init(color: TrainingHomeStyle.cardBlack.opacity(0.9), location: 0.82),
                                           .init(color: TrainingHomeStyle.cardBlack, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            Text(category).font(.caption2.weight(.semibold)).tracking(0.6)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                        }
                        Spacer(minLength: 16)
                        Text(title)
                            .font(TrainingHomeStyle.display(30, relativeTo: .title))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.bottom, 4)
                        Text(subtitle).font(.caption).lineSpacing(3)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(14)
                }
                .frame(height: imageHeight)
                .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(actionLabel).font(.caption.weight(.bold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(primary ? TrainingHomeStyle.buttonInk : TrainingHomeStyle.lime)
                .background(primary ? TrainingHomeStyle.lime : TrainingHomeStyle.cardFooter)
            }
            .background(TrainingHomeStyle.cardBlack)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(actionLabel)")
        .accessibilityHint(subtitle.replacingOccurrences(of: "\n", with: " "))
    }
}

#Preview("Training home") {
    RootShellView()
}
