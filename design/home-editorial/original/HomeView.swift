import SwiftUI

struct HomeView: View {
    let snapshot: HomeSnapshot
    let onSelect: (TrainingModule) -> Void
    var onNotifications: () -> Void = {}
    var onProfile: () -> Void = {}
    var onMilestone: () -> Void = {}

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: HomeSurface.sectionSpacing) {
                HomeHeaderView(snapshot: snapshot, onNotifications: onNotifications, onProfile: onProfile)
                HomeHeroView(tagline: snapshot.tagline)
                ModuleGridView(modules: snapshot.modules, onSelect: onSelect)
                MilestoneCardView(milestone: snapshot.milestone, action: onMilestone)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, HomeSurface.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .background { HomeBackdrop() }
    }
}

#Preview("Home Light") {
    RootShellView().preferredColorScheme(.light)
}

#Preview("Home Dark") {
    RootShellView().preferredColorScheme(.dark)
}
