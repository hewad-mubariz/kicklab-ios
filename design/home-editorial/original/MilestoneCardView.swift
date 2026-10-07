import SwiftUI

struct MilestoneCardView: View {
    let milestone: Milestone
    var action: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 33))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.43), Theme.star, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Theme.star.opacity(0.35), radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(milestone.title).font(.system(size: 13, weight: .bold))
                    Text(milestone.detail)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        ProgressView(value: milestone.progress)
                            .tint(HomeSurface.green(scheme))
                        Text(milestone.progressLabel)
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .regular))
            }
            .foregroundStyle(HomeSurface.ink(scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(HomePanel())
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel("\(milestone.title). \(milestone.detail). Progress \(milestone.progressLabel)")
        .accessibilityIdentifier("next-milestone")
    }
}
