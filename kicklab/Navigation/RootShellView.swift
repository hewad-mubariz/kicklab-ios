import AppTrackingTransparency
import PhotosUI
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("kicklab.appearance") private var appearance = "system"
    @AppStorage("kicklab.welcome.completed") private var hasEnteredApp = false
    @AppStorage(JugglingRecords.bestKey) private var personalBest = 0
    @State private var capture: HomeCapture?
    @State private var sheet: HomeSheet?
    @State private var showImport = false
    @State private var importedVideo: PhotosPickerItem?
    @State private var showsLeaderboard = false
    @State private var recordsAfterLeaderboard = false
    @State private var showsProfile = false
    @State private var showsHistory = false
    @State private var showsUpdateAlert = false
    @ObservedObject private var updateNotice = AppUpdateNotice.shared
    @ObservedObject private var adMeasurement = MetaAdsMeasurement.shared
    @Namespace private var zoom
    private var accountBest: Int { account.user == nil ? personalBest : player.personalBest }

    private var homeIsReadyForNotice: Bool {
        hasEnteredApp && scenePhase == .active && capture == nil && sheet == nil &&
        !showImport && !showsLeaderboard && !showsProfile && !showsHistory
    }

    /// The tracking question comes after a first finished training (or the third launch), on a calm home screen.
    private var canRequestAdPermission: Bool {
        homeIsReadyForNotice && adMeasurement.wantsPermission && !showsUpdateAlert
    }

    private var canShowUpdateAlert: Bool {
        // Let Apple's tracking prompt finish before presenting a second native dialog.
        let trackingChoicePending = adMeasurement.isAvailable && adMeasurement.wantsPermission &&
            adMeasurement.authorizationStatus == .notDetermined
        return homeIsReadyForNotice && updateNotice.shouldPrompt &&
            !adMeasurement.isRequesting && !trackingChoicePending
    }

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
            if hasEnteredApp {
                HomeView(
                    personalBest: accountBest,
                    onJuggling: { capture = HomeCapture(mode: .juggling) },
                    onPowerShot: { capture = HomeCapture(mode: .powerShot) },
                    onImport: { showImport = true },
                    onProfile: { showsProfile = true },
                    onSetupGuide: { sheet = .setup },
                    onLeaderboard: { showsLeaderboard = true },
                    onLeaderboardRules: { sheet = .leaderboardRules },
                    onHistory: { showsHistory = true },
                    leaderboardZoom: zoom,
                    profileZoom: zoom
                )
            } else {
                SignInView(presentation: .welcome) {
                    hasEnteredApp = true
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: hasEnteredApp)
        // Prepare the tracking model for this phone once per build, away from the camera opening.
        .task(id: hasEnteredApp) {
            guard hasEnteredApp else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            TrackingModelPrewarm.runIfNeeded()
        }
        .task(id: canRequestAdPermission) {
            guard canRequestAdPermission, adMeasurement.isAvailable else { return }
            // Let the replay close first; cancel if a camera, sign-in, or sheet opens.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled else { return }
            await MetaAdsMeasurement.shared.requestPermission()
        }
        .task(id: canShowUpdateAlert) {
            guard canShowUpdateAlert else { return }
            // Wait for a dismissed sheet or system prompt to finish its transition.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled, canShowUpdateAlert else { return }
            showsUpdateAlert = true
        }
        .background { updateAlert }
        #if DEBUG && TOUCH_COUNTING_DEBUG
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Touch test · Clear chest allowed")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(.yellow.opacity(0.2))
        }
        #endif
        .modifier(SoftHaloOpening())
        .debugRuntimeOverlay()
        .overlay(alignment: .top) {
            if hasEnteredApp && sheet == nil && !showsProfile {
                AccountErrorBanner().padding()
            }
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
        .fullScreenCover(isPresented: $showsLeaderboard, onDismiss: {
            if recordsAfterLeaderboard {
                recordsAfterLeaderboard = false
                capture = HomeCapture(mode: .juggling)
            }
        }) {
            LeaderboardView(yourName: account.user?.name, onClose: { showsLeaderboard = false }, onRecord: {
                recordsAfterLeaderboard = true; showsLeaderboard = false
            })
                .leaderboardZoom(in: zoom)
                .preferredColorScheme(preferredScheme)
        }
        .fullScreenCover(isPresented: $showsProfile) {
            TrainingProfileView(personalBest: accountBest, appearance: $appearance)
            .navigationTransition(.zoom(sourceID: "profile", in: zoom))
            .preferredColorScheme(preferredScheme)
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: TrainingCameraGuide()
            case .leaderboardRules: LeaderboardRulesView()
            }
        }
        .sheet(isPresented: $showsHistory) {
            SessionHistoryView(store: player.history)
                .preferredColorScheme(preferredScheme)
        }
    }

    // Scope the neutral system tint to the alert; the rest of the app keeps its accent.
    private var updateAlert: some View {
        Color.clear
            .alert("Update available", isPresented: $showsUpdateAlert, presenting: updateNotice.available) { _ in
                Button("Update") {
                    updateNotice.dismiss()
                    openURL(AppUpdateNotice.appStoreURL)
                }
                Button("Not now", role: .cancel) { updateNotice.dismiss() }
            } message: { release in
                Text(String(localized: "Juggle Dude \(release.version) is here", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                    + "\n\n" + release.headline)
            }
            .tint(.primary)
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
    case leaderboardRules
    var id: String { rawValue }
}
