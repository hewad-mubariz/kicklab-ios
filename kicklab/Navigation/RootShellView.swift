import PhotosUI
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerStore
    @AppStorage("kicklab.appearance") private var appearance = "system"
    @AppStorage("kicklab.welcome.completed") private var hasEnteredApp = false
    @AppStorage("kicklab.juggling.personalBest") private var personalBest = 0
    @State private var capture: HomeCapture?
    @State private var sheet: HomeSheet?
    @State private var showImport = false
    /// Signing in from Profile returns to the same main sign-in view as the first launch.
    @State private var signingIn = false
    @State private var importedVideo: PhotosPickerItem?
    @State private var showsLeaderboard = false
    @State private var showsProfile = false
    @State private var signInAfterProfile = false
    @State private var showsHistory = false
    @Namespace private var zoom
    private var accountBest: Int { account.user == nil ? personalBest : player.personalBest }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            // The sign-in view hands over itself once signed in, after its "You're in" moment.
            if hasEnteredApp && !signingIn {
                HomeView(
                    personalBest: accountBest,
                    onJuggling: { capture = HomeCapture(mode: .juggling) },
                    onPowerShot: { capture = HomeCapture(mode: .powerShot) },
                    onImport: { showImport = true },
                    onProfile: { showsProfile = true },
                    onSetupGuide: { sheet = .setup },
                    onLeaderboard: { showsLeaderboard = true },
                    onHistory: { showsHistory = true },
                    leaderboardZoom: zoom,
                    profileZoom: zoom
                )
            } else {
                SignInView(presentation: signingIn ? .profile : .welcome) {
                    signingIn = false
                    hasEnteredApp = true
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: signingIn)
        .animation(.smooth(duration: 0.4), value: hasEnteredApp)
        .modifier(SoftHaloOpening())
        .overlay(alignment: .top) {
            if hasEnteredApp && sheet == nil && !showsProfile && !signingIn { AccountErrorBanner().padding() }
        }
        // Keep presentation anchored to the root while welcome becomes home.
        .preferredColorScheme(preferredScheme)
        .tint(Theme.accent)
        .photosPicker(isPresented: $showImport, selection: $importedVideo, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: importedVideo) { _, _ in openImportedVideoIfReady() }
        .onChange(of: showImport) { _, _ in openImportedVideoIfReady() }
        .fullScreenCover(item: $capture) { destination in
            switch destination.mode {
            case .juggling:
                RecordView(initialVideo: destination.importedVideo)
            case .powerShot:
                BallDistanceView()
            }
        }
        .fullScreenCover(isPresented: $showsLeaderboard) {
            LeaderboardView(yourName: account.user?.name) { showsLeaderboard = false }
                .leaderboardZoom(in: zoom)
                .preferredColorScheme(preferredScheme)
        }
        .fullScreenCover(isPresented: $showsProfile, onDismiss: {
            // Keep the source icon mounted until the reverse zoom has finished.
            if signInAfterProfile {
                signInAfterProfile = false
                signingIn = true
            }
        }) {
            TrainingProfileView(personalBest: accountBest, appearance: $appearance) {
                signInAfterProfile = true
                showsProfile = false
            }
            .navigationTransition(.zoom(sourceID: "profile", in: zoom))
            .preferredColorScheme(preferredScheme)
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: TrainingCameraGuide()
            }
        }
        .sheet(isPresented: $showsHistory) {
            SessionHistoryView(store: player.history)
                .preferredColorScheme(preferredScheme)
        }
    }

    private func openImportedVideoIfReady() {
        // The picker must finish dismissing before presenting the analysis screen.
        guard !showImport, let item = importedVideo, capture == nil else { return }
        importedVideo = nil
        capture = HomeCapture(mode: .juggling, importedVideo: item)
    }
}

private struct HomeCapture: Identifiable {
    enum Mode { case juggling, powerShot }
    let id = UUID()
    let mode: Mode
    var importedVideo: PhotosPickerItem?
}

private enum HomeSheet: String, Identifiable {
    case setup
    var id: String { rawValue }
}
