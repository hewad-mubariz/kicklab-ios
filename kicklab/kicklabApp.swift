//
//  kicklabApp.swift
//  kicklab
//

import SwiftUI
import StoreKit

#if !BALL_DETECTION_DEBUG && !POWER_SHOT_DEBUG
@main
struct kicklabApp: App {
    @UIApplicationDelegateAdaptor(VideoSaveAppDelegate.self) private var appDelegate
    @StateObject private var account: AccountStore
    @StateObject private var player: PlayerStore
    @StateObject private var subscriptions: SubscriptionStore
    @StateObject private var videoWork = VideoBackgroundWork.shared
    @Environment(\.scenePhase) private var scenePhase
    init() {
        Task.detached(priority: .utility) { try? VideoSafetyPolicy.cleanExpiredExports() }
        #if DEBUG
        let account = ProfileEditorReview.requested ? ProfileEditorReview.account() :
            (AccountDeletionReview.requested ? AccountDeletionReview.account() :
            (SessionHistoryReview.requested ? AccountStore(service: nil) : AccountStore.live()))
        #else
        let account = AccountStore.live()
        #endif
        _account = StateObject(wrappedValue: account)
        _subscriptions = StateObject(wrappedValue: SubscriptionStore.live(account: account))
        #if DEBUG
        _player = StateObject(wrappedValue: ProfileEditorReview.requested ? ProfileEditorReview.player() :
            (AccountDeletionReview.requested ? AccountDeletionReview.player() : PlayerStore.live(account: account)))
        #else
        _player = StateObject(wrappedValue: PlayerStore.live(account: account))
        #endif
        #if TOUCH_COUNTER_BETA
        TouchCountingDebugProfile.writeLaunchReport()
        #endif
        #if DEBUG
        // Rankings are always live. A sample board appears only for the launch a design
        // review asks for one, and a choice saved by older builds is dropped.
        UserDefaults.standard.removeObject(forKey: LeaderboardPreviewScenario.defaultsKey)
        if let raw = SessionDesignReview.argument("--leaderboard-preview"),
           let scenario = LeaderboardPreviewScenario(rawValue: raw) {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[LeaderboardPreviewScenario.defaultsKey] = scenario.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        #if TOUCH_COUNTING_DEBUG
        UserDefaults.standard.set(true, forKey: "kicklab.welcome.completed")
        TouchCountingDebugProfile.writeLaunchReport()
        #endif
        // Reset once before the first view is created. A UserDefaults launch
        // override would keep forcing false even after the guest button writes true.
        if ProcessInfo.processInfo.arguments.contains("--reset-welcome") {
            UserDefaults.standard.removeObject(forKey: "kicklab.welcome.completed")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ball-distance-design") {
                BallDistanceView()
            } else if ProcessInfo.processInfo.arguments.contains("--shot-geometry-capture") {
                ShotGeometryCaptureView()
            } else {
            if SessionDesignReview.argument("--background-video-review") != nil {
                BackgroundVideoReview()
            } else if let path = SessionDesignReview.argument("--thermal-review") {
                ThermalVideoReview(configurationURL: SessionDesignReview.fileURL(path))
            } else if let path = SessionDesignReview.argument("--effects-video") {
                EffectsVideoReview(url: SessionDesignReview.fileURL(path))
            } else if let screen = SessionDesignReview.requestedScreen {
                SessionDesignReview(screen: screen)
            } else {
                ContentView()
            }
            }
            #else
            ContentView()
            #endif
            }
            .environmentObject(account)
            .environmentObject(player)
            .environmentObject(subscriptions)
            .alert("Video task interrupted", isPresented: Binding(
                get: { videoWork.interruptedMessage != nil },
                set: { if !$0 { videoWork.interruptedMessage = nil } })) {
                Button("OK") { videoWork.interruptedMessage = nil }
            } message: { Text(videoWork.interruptedMessage ?? "") }
            .task {
                await subscriptions.refreshEntitlements()
                #if DEBUG
                if let folder = SessionDesignReview.argument("--touch-contact-replay") {
                    await TouchContactReplay.run(folderName: folder)
                }
                if let folder = SessionDesignReview.argument("--rf-full-app-check") {
                    await RFAppValidation.run(folderName: folder)
                }
                #if TOUCH_COUNTING_DEBUG
                if let folder = SessionDesignReview.argument("--frame-rate-replay") {
                    await FrameRateReplay.run(folderName: folder)
                }
                #endif
                // Read-only device smoke check outside StoreKit Test's local catalog.
                if ProcessInfo.processInfo.arguments.contains("--verify-subscription-catalog") {
                    await subscriptions.loadProducts()
                    for (plan, product) in subscriptions.products {
                        let metadata = try? JSONSerialization.jsonObject(with: product.jsonRepresentation) as? [String: Any]
                        print("JUGGLE_DUDE_CATALOG", plan.productID, product.displayPrice,
                              "APPLE_ID", metadata?["id"] ?? "unavailable")
                    }
                    print("JUGGLE_DUDE_CATALOG_DONE", subscriptions.products.count,
                          subscriptions.catalogError ?? "OK")
                }
                if ProcessInfo.processInfo.arguments.contains("--verify-subscription-access") {
                    for await result in Transaction.currentEntitlements {
                        guard case .verified(let transaction) = result,
                              ProPlan(productID: transaction.productID) != nil else { continue }
                        // No receipt, transaction ID or account details in diagnostic output.
                        print("JUGGLE_DUDE_ENTITLEMENT", transaction.productID,
                              "ENVIRONMENT", transaction.environment.rawValue,
                              "REVOKED", transaction.revocationDate != nil)
                    }
                    print("JUGGLE_DUDE_ACCESS", subscriptions.activePlan?.rawValue ?? "none",
                          "CHECKED", subscriptions.hasCheckedAccess)
                }
                #endif
            }
            .task(id: account.user?.id) { await player.useAccount(account.user) }
            .task(id: account.user?.id) { await subscriptions.useAccount(account.user?.id) }
            .task {
                #if DEBUG
                await ProfileEditorReview.refreshWhileReviewing(player)
                #endif
            }
            .onOpenURL { url in Task { await account.handleCallback(url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                Task { await account.handleCallback(url) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { ProductAnalytics.shared.track(.appOpened) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    VideoSaveCompletion.shared.becameActive()
                    Task { await subscriptions.refreshEntitlements() }
                }
                Task {
                    await account.setActive(phase == .active)
                    if phase == .active { await player.refresh() }
                }
            }
        }
    }
}
#endif
