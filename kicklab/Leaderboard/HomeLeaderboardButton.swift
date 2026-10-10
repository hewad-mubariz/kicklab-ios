import SwiftUI

/// Sits beside the profile button on Home, in the same glass, and zooms open the leaderboard.
struct HomeLeaderboardButton: View {
    let action: () -> Void
    var zoom: Namespace.ID? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "trophy")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(TrainingHomeStyle.accent(scheme))
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HomeIconZoomSource(id: "leaderboard", zoom: zoom))
        .accessibilityLabel("Open leaderboard")
        .accessibilityIdentifier("home-leaderboard")
    }
}

extension View {
    /// The leaderboard grows out of the Home trophy button and shrinks back into it.
    func leaderboardZoom(in zoom: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: "leaderboard", in: zoom))
    }
}
