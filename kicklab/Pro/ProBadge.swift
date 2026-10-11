import SwiftUI

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(0.5)
            .foregroundStyle(ProPass.ink)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(ProPass.lime, in: .capsule)
            .accessibilityLabel("Pro")
            .accessibilityIdentifier("pro-style-badge")
    }
}
