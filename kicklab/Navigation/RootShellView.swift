import AppTrackingTransparency
import PhotosUI
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("kicklab.appearance") private var appearance = "system"
    @AppStorage("kicklab.welcome.completed") private var hasEnteredApp = false
    @AppStorage(JugglingRecords.bestKey) private var personalBest = 0
    @AppStorage("kicklab.profile.displayName") private var guestName = ""
    @AppStorage(ProfilePhoto.versionKey) private var guestPhotoVersion = 0
    @State private var showsProfile = false
    @Namespace private var zoom
    @State private var capture: HomeCapture?
    @State private var sheet: HomeSheet?
    @State private var showImport = false
    @State private var importedVideo: PhotosPickerItem?
    @State private var selectedTab: AppTab = .home
    @State private var showsHistory = false
    @State private var showsUpdateAlert = false
    @ObservedObject private var updateNotice = AppUpdateNotice.shared
    @ObservedObject private var adMeasurement = MetaAdsMeasurement.shared
    @ObservedObject private var notificationNavigation = AppNotificationNavigation.shared
    @ObservedObject private var practiceNotifications = PracticeNotifications.shared
    private var accountBest: Int { account.user == nil ? personalBest : player.personalBest }
    /// The name the profile shows; Home greets with its first word.
    private var homeName: String? {
        let name = account.user == nil ? guestName : (player.profile?.displayName ?? account.user?.name ?? "")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var shellIsReady: Bool {
        hasEnteredApp && scenePhase == .active && capture == nil && sheet == nil &&
        !showImport && !showsHistory && !showsProfile
    }

    private var homeIsReadyForNotice: Bool { shellIsReady && selectedTab == .home }

    private var canRequestPracticePermission: Bool {
        homeIsReadyForNotice && practiceNotifications.shouldAskAfterSession &&
        !showsUpdateAlert && !adMeasurement.isRequesting && notificationNavigation.pending == nil
    }

    /// Give the first-session notification question this launch; tracking can wait until another launch.
    private var canRequestAdPermission: Bool {
        homeIsReadyForNotice && adMeasurement.wantsPermission && !showsUpdateAlert &&
        notificationNavigation.pending == nil &&
        !practiceNotifications.shouldAskAfterSession && !practiceNotifications.isRequestingSessionPermission &&
        !practiceNotifications.presentedSessionPromptThisLaunch
    }

    private var canOpenNotification: Bool {
        shellIsReady && !showsUpdateAlert && !adMeasurement.isRequesting &&
        !practiceNotifications.isRequestingSessionPermission
    }

    private var canShowUpdateAlert: Bool {
        // Let Apple's tracking prompt finish before presenting a second native dialog.
        let trackingChoicePending = adMeasurement.isAvailable && adMeasurement.wantsPermission &&
            adMeasurement.authorizationStatus == .notDetermined
        return homeIsReadyForNotice && updateNotice.shouldPrompt &&
            notificationNavigation.pending == nil &&
            !adMeasurement.isRequesting && !trackingChoicePending &&
            !practiceNotifications.shouldAskAfterSession && !practiceNotifications.isRequestingSessionPermission &&
            !practiceNotifications.presentedSessionPromptThisLaunch
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
                mainTabs
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
        .task(id: canRequestPracticePermission) {
            guard canRequestPracticePermission else { return }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled, canRequestPracticePermission else { return }
            await practiceNotifications.requestAfterSessionIfNeeded()
            await RemotePracticeNotifications.shared.refresh()
        }
        .task(id: canRequestAdPermission) {
            guard canRequestAdPermission, adMeasurement.isAvailable else { return }
            // Let the replay close first; cancel if a camera, sign-in, or sheet opens.
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled, canRequestAdPermission else { return }
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
        .onChange(of: importedVideo) { _, item in
            #if DEBUG
            if item != nil { ImportFlowAudit.selected() }
            #endif
            openImportedVideoIfReady()
        }
        .onChange(of: showImport) { _, _ in openImportedVideoIfReady() }
        .onChange(of: notificationNavigation.pending, initial: true) { _, _ in openNotificationIfReady() }
        .onChange(of: canOpenNotification) { _, _ in openNotificationIfReady() }
        .task(id: notificationNavigation.pending?.id) {
            // A tab may own a sheet (profile editing, rules, player details).
            // Keep the request pending until that presentation has finished.
            while notificationNavigation.pending != nil {
                openNotificationIfReady()
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
        .fullScreenCover(item: $capture) { destination in
            switch destination.mode {
            case .juggling:
                RecordView(initialVideo: destination.importedVideo, challengeTarget: destination.challengeTarget)
            case .powerShot:
                BallDistanceView()
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup: TrainingCameraGuide()
            case .leaderboardRules: LeaderboardRulesView()
            }
        }
        .fullScreenCover(isPresented: $showsProfile) {
            TrainingProfileView(personalBest: accountBest, appearance: $appearance)
                .navigationTransition(.zoom(sourceID: "profile", in: zoom))
                .preferredColorScheme(preferredScheme)
        }
        .sheet(isPresented: $showsHistory) {
            SessionHistoryView(store: player.history)
                .preferredColorScheme(preferredScheme)
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.home) {
                HomeSessionsObserver(store: player.history) { sessions in
                    HomeView(
                        personalBest: accountBest,
                        onJuggling: { capture = HomeCapture(mode: .juggling) },
                        onPowerShot: { capture = HomeCapture(mode: .powerShot) },
                        onImport: { showImport = true },
                        onProfile: { showsProfile = true },
                        onSetupGuide: { sheet = .setup },
                        onLeaderboard: { selectedTab = .leaderboard },
                        onLeaderboardRules: { sheet = .leaderboardRules },
                        onHistory: { showsHistory = true },
                        profileZoom: zoom,
                        showsDestinationShortcuts: false,
                        sessions: sessions,
                        playerName: homeName,
                        onGoal: { target in capture = HomeCapture(mode: .juggling, challengeTarget: target) },
                        profilePhoto: HomeProfilePhoto(accountPhoto: account.user == nil ? nil : player.avatarData,
                                                       guestVersion: account.user == nil ? guestPhotoVersion : nil)
                    )
                }
            } label: {
                Label("Home", systemImage: "house")
            }
            Tab(value: AppTab.learn) {
                LearnHubView()
            } label: {
                Label("Learn", systemImage: "graduationcap")
            }
            Tab(value: AppTab.challenges) {
                JugglingChallengesView(personalBest: accountBest) { target in
                    capture = HomeCapture(mode: .juggling, challengeTarget: target)
                }
            } label: {
                Label("Challenges", systemImage: "flag.checkered")
            }
            Tab(value: AppTab.wallGame) {
                WallGameHubView(onClose: { selectedTab = .home })
            } label: {
                Label("Wall Game", systemImage: "square.grid.3x2")
            }
            Tab(value: AppTab.leaderboard) {
                LeaderboardView(yourName: account.user?.name, onRecord: {
                    capture = HomeCapture(mode: .juggling)
                })
            } label: {
                Label("Leaderboard", systemImage: "trophy")
            }
        }
        .tint(TrainingHomeStyle.accent(preferredScheme ?? scheme))
        // The system tab bar: on iOS 26 and later its Liquid Glass selection stretches between tabs and it
        // can be dragged across. It stays on screen while a tab scrolls (the owner prefers it that way).
        .tabBarStaysVisible()
        .sensoryFeedback(.selection, trigger: selectedTab)
        // A leaderboard place belongs to the account that earned it.
        .onChange(of: account.user?.id) { _, _ in
            JuggleWidgetData.update { data in data.weekRank = nil; data.allTimeRank = nil }
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

    private func openNotificationIfReady() {
        guard let request = notificationNavigation.pending else { return }
        if request.destination == .leaderboard && selectedTab == .leaderboard {
            notificationNavigation.consume()
            return
        }
        guard canOpenNotification, !hasPresentedScreen else { return }
        notificationNavigation.consume()
        // Wait for active work to close. A tap never starts recording or discards a replay.
        switch request.destination {
        case .practice: capture = HomeCapture(mode: .juggling)
        case .leaderboard: selectedTab = .leaderboard
        }
    }

    private var hasPresentedScreen: Bool {
        func isPresenting(_ controller: UIViewController) -> Bool {
            controller.presentedViewController != nil || controller.isBeingDismissed ||
            controller.children.contains(where: isPresenting)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).filter(\.isKeyWindow)
            .compactMap(\.rootViewController).contains(where: isPresenting)
    }
}

private struct HomeCapture: Identifiable {
    enum Mode { case juggling, powerShot }
    let id = UUID()
    let mode: Mode
    var importedVideo: PhotosPickerItem?
    var challengeTarget: Int?
}

private enum HomeSheet: String, Identifiable {
    case setup
    case leaderboardRules
    var id: String { rawValue }
}

private extension View {
    @ViewBuilder
    func tabBarStaysVisible() -> some View {
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior(.never) } else { self }
    }
}
