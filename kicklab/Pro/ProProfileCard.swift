import SwiftUI

/// The way into Juggle Dude Pro from Profile; presents the paywall itself.
struct ProProfileCard: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsPaywall = false

    var body: some View {
        VStack(spacing: 8) {
        // Keep Restore reachable even when StoreKit's cached state still says Pro.
        // Apple billing remains available from the Pro screen's Manage button.
        Button { showsPaywall = true } label: {
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
                    Text(subscriptions.isPro ? "Manage your subscription" : "Effects, balls, overlays and shot camera tools")
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
        .fullScreenCover(isPresented: $showsPaywall) {
            ProPaywallView { showsPaywall = false }
        }
        if subscriptions.checkingAccountAccess || subscriptions.accountLinkMessage != nil {
            VStack(spacing: 6) {
                if let message = subscriptions.accountLinkMessage {
                    Text(message).font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
                        .multilineTextAlignment(.center)
                }
                // A purchase owned by another existing account cannot be fixed by retrying.
                if !subscriptions.accountLinkedElsewhere {
                Button { Task { await subscriptions.retryAccountSync() } } label: {
                    HStack(spacing: 6) {
                        if subscriptions.checkingAccountAccess { ProgressView().controlSize(.small) }
                        Text(subscriptions.checkingAccountAccess ? "Syncing account…" : "Retry account sync")
                    }.font(.caption.weight(.semibold))
                }
                .disabled(subscriptions.checkingAccountAccess)
                .accessibilityIdentifier("profile-pro-account-sync")
                }
            }.padding(.horizontal, 12)
        }
        }
    }
}
