import SwiftUI

struct HomeHeaderView: View {
    let snapshot: HomeSnapshot
    var onNotifications: () -> Void = {}
    var onProfile: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onProfile) {
                ZStack {
                    Circle().fill(HomeSurface.panel(scheme))
                    Image("avatar-player")
                        .resizable().scaledToFill()
                        .clipShape(Circle())
                        .padding(3)
                }
                .frame(width: 43, height: 43)
                .overlay(Circle().strokeBorder(HomeSurface.rim(scheme), lineWidth: 1.5))
                .shadow(color: Theme.brand.opacity(scheme == .dark ? 0.25 : 0), radius: 7)
            }
            .buttonStyle(HomePressStyle())
            .accessibilityLabel("Open profile")

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.greeting)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("Ready to train today?")
                    .font(.system(size: 11.5))
                    .foregroundStyle(HomeSurface.mutedInk(scheme))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Button(action: onNotifications) {
                Image(systemName: "bell")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 42, height: 44)
                    .background(HomeSurface.panel(scheme).opacity(0.6), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if snapshot.hasUnreadNotifications {
                            Circle().fill(.red).frame(width: 7, height: 7).offset(x: -7, y: 5)
                        }
                    }
            }
            .buttonStyle(HomePressStyle())
            .accessibilityLabel("Notifications")
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Text("🔥").font(.system(size: 20))
                    Text("\(snapshot.streakDays)")
                        .font(.system(size: 20, weight: .bold)).monospacedDigit()
                }
                Text("Day Streak").font(.system(size: 9))
            }
            .frame(width: 65, height: 53)
            .background(HomeSurface.panel(scheme).opacity(0.65), in: RoundedRectangle(cornerRadius: 15))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(snapshot.streakDays) day streak")
        }
        .foregroundStyle(HomeSurface.ink(scheme))
    }
}
