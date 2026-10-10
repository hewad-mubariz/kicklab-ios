import SwiftUI
import StoreKit

/// The way into Juggle Dude Pro from Profile; presents the paywall itself.
struct ProProfileCard: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsPaywall = false
    @State private var managing = false

    var body: some View {
        Button {
            if subscriptions.isPro { managing = true }
            else { showsPaywall = true }
        } label: {
            HStack(spacing: 14) {
                Text("PRO")
                    .font(ProPass.display(20)).tracking(1)
                    .padding(.top, 3)
                    .foregroundStyle(ProPass.ink)
                    .frame(width: 52, height: 34)
                    .background(ProPass.lime, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(subscriptions.isPro ? "Juggle Dude Pro · Active" : "Juggle Dude Pro").font(.body.weight(.semibold))
                        .accessibilityIdentifier("profile-pro-status")
                    Text(subscriptions.isPro ? "Manage your subscription" : "Extra effects, ball styles and motion overlays")
                        .font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(ProPass.lime.opacity(scheme == .dark ? 0.35 : 0.6)) }
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(SessionPressStyle(scale: 0.97))
        .accessibilityIdentifier("profile-pro")
        .manageSubscriptionsSheet(isPresented: $managing)
        .onChange(of: managing) { _, value in
            if !value { Task { await subscriptions.refreshEntitlements() } }
        }
        .fullScreenCover(isPresented: $showsPaywall) {
            ProPaywallView { showsPaywall = false }
        }
    }
}
