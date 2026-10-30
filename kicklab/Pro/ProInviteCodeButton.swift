import StoreKit
import SwiftUI

/// Invite codes are Apple subscription offers. Closing Apple's sheet alone never
/// grants access; the existing verified transaction listener activates Pro.
struct ProInviteCodeButton: View {
    @Binding var isRedeeming: Bool
    var accessibilityID = "pro-redeem-invite"
    var onUnlocked: (() -> Void)? = nil
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsRedemption = false
    @State private var hadPro = false
    @State private var completionResult: Result<Void, Error>?
    @State private var notice: InviteNotice?

    var body: some View {
        Group {
            if #available(iOS 27.0, *) {
                redemptionButton.offerCodeRedemption(options: [], isPresented: $showsRedemption) { result in
                    Task { @MainActor in
                        do {
                            // New StoreKit APIs return the transaction directly;
                            // process it now rather than waiting for another launch.
                            try await subscriptions.receiveOfferCode(try result.get())
                            await received(.success(()))
                        } catch {
                            await received(.failure(error))
                        }
                    }
                }
            } else {
                redemptionButton.offerCodeRedemption(isPresented: $showsRedemption) { result in
                    Task { @MainActor in await received(result) }
                }
            }
        }
        .onChange(of: showsRedemption) { _, showing in
            if !showing { Task { @MainActor in await finishIfDismissed() } }
        }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var redemptionButton: some View {
        Button {
            guard !subscriptions.busy, !isRedeeming else { return }
            hadPro = subscriptions.isPro
            completionResult = nil
            isRedeeming = true
            showsRedemption = true
        } label: {
            HStack(spacing: 8) {
                if isRedeeming {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "gift")
                }
                Text(isRedeeming ? "Checking invite…" : "Redeem invite code")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(subscriptions.busy || isRedeeming)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityHint("Opens Apple’s code redemption sheet to review and redeem your Pro offer.")
    }

    @MainActor
    private func received(_ result: Result<Void, Error>) async {
        completionResult = result
        if case .failure = result { showsRedemption = false }
        await finishIfDismissed()
    }

    @MainActor
    private func finishIfDismissed() async {
        // Presentation completion and sheet dismissal can arrive in either order.
        // Never dismiss the paywall from underneath Apple's native sheet.
        guard isRedeeming, !showsRedemption, let result = completionResult else { return }
        completionResult = nil
        // A transaction returned directly has already refreshed access. A second
        // immediate history read could discard it before StoreKit catches up.
        if #unavailable(iOS 27.0) { await subscriptions.refreshEntitlements() }
        isRedeeming = false
        if !hadPro && subscriptions.isPro {
            if let onUnlocked { onUnlocked() }
            else {
                notice = InviteNotice(title: "Pro is ready", message: "Your Pro access is active. Enjoy all Pro features.")
            }
        } else if case .failure(let error) = result, !Self.isCancellation(error) {
            notice = InviteNotice(title: "Couldn’t redeem invite", message: "Please try again. If Apple already accepted your code, use Restore purchases on the Pro screen.")
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? StoreKitError, case .userCancelled = error { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

private struct InviteNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
