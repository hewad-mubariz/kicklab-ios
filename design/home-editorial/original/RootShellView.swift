import SwiftUI

struct RootShellView: View {
    @AppStorage("kicklab.appearance") private var appearance = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: AppTab = .home
    @State private var homeSnapshot = HomeSnapshot.preview
    @State private var showJuggling = false
    @State private var selectedModule: TrainingModule?
    @State private var showNotifications = false

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        ZStack {
            HomeBackdrop()
            Group {
                switch selection {
                case .home:
                    HomeView(snapshot: homeSnapshot, onSelect: handleModule,
                             onNotifications: {
                                 showNotifications = true
                                 homeSnapshot.hasUnreadNotifications = false
                             }, onProfile: { select(.profile) }, onMilestone: { select(.progress) })
                case .train:
                    TrainingHubView(modules: homeSnapshot.modules, onSelect: handleModule)
                case .progress:
                    ProgressHubView(milestone: homeSnapshot.milestone) { showJuggling = true }
                case .challenges:
                    ChallengesHubView(milestone: homeSnapshot.milestone) { showJuggling = true }
                case .profile:
                    ProfileHubView(snapshot: homeSnapshot, appearance: $appearance)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: $selection)
        }
        .preferredColorScheme(preferredScheme)
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $showJuggling) {
            RecordView()
        }
        .sheet(item: $selectedModule) { module in
            ModePreviewSheet(module: module)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNotifications) {
            NotificationsSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func select(_ tab: AppTab) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selection = tab }
    }

    private func handleModule(_ module: TrainingModule) {
        guard module.isAvailable else { return }
        switch module.destination {
        case .juggling: showJuggling = true
        case .challenges: select(.challenges)
        case .stats: select(.progress)
        case .targetShoot, .freeKick, .penalties: selectedModule = module
        case .none: break
        }
    }
}
