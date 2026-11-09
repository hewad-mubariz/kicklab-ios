import SwiftUI
import StoreKit

/// Juggle Dude Pro: compact, static previews of real ball skins above the
/// headline and plans. The paywall never initializes the effects renderer.
///
/// Built with App Review in mind: an always-visible close button, the billed price as the
/// strongest price, renewal terms beside the button, and Restore, Terms and Privacy links.
struct ProPaywallView: View {
    let onClose: () -> Void
    var onUnlocked: (() -> Void)? = nil
    @State private var deliveredUnlock = false
    @Environment(\.dismiss) private var dismiss
    @State private var plan = ProPlan.yearly
    @State private var appeared = false
    @State private var trackedView = false
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openURL) private var openURL
    @State private var managing = false
    @State private var redeemingInvite = false
    private var working: Bool { subscriptions.busy || redeemingInvite }
    private var offer: ProOffer? { subscriptions.offer(for: plan) }
    @State private var notice: ProNotice?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ProPassHero(appeared: appeared, topInset: proxy.safeAreaInsets.top)
                    VStack(spacing: 12) {
                        features
                        Text("Recording, basic replays and basic export stay free.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pro-free-features")
                        ProInviteCodeButton(isRedeeming: $redeemingInvite) {
                            if onUnlocked != nil { deliverUnlock() }
                            else { close() }
                        }
                        .foregroundStyle(ProPass.lime)
                        plans.padding(.top, 2)
                        if subscriptions.isPro {
                            Text("To change plans, tap Monthly or Yearly and choose your plan in Apple’s subscription settings.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("pro-change-plan-help")
                        }
                        purchase.padding(.top, 2)
                        if let error = subscriptions.catalogError, !subscriptions.isPro {
                            VStack(spacing: 4) {
                                Text(error).font(.caption).multilineTextAlignment(.center)
                                Button("Try again") { Task { await subscriptions.loadProducts() } }
                                    .font(.caption.weight(.semibold)).tint(ProPass.lime)
                                    .accessibilityIdentifier("pro-retry")
                            }
                        }
                        Text(subscriptions.isPro ? (subscriptions.isAccountOnlyPro
                            ? String(localized: "Pro is active through your Juggle Dude account. Manage billing with the Apple Account used to subscribe.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                            : String(localized: "Your Pro subscription is active on this Apple Account. Manage your plan or cancel through Apple.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)) : offer?.renewalTerms ?? String(localized: "Choose a plan once App Store prices have loaded. Payment is confirmed with Apple.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .contentTransition(.interpolate)
                            .accessibilityIdentifier("pro-renewal-terms")
                        #if DEBUG
                        // Testing aid only: customers see the renewal terms above, not raw expiry times.
                        if let end = subscriptions.localAccessUntil {
                            Text("Apple access verified until \(end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("pro-access-until")
                        }
                        #endif
                        links
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, max(12, proxy.safeAreaInsets.bottom))
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .background(ProPass.background.ignoresSafeArea())
        #if DEBUG
        .safeAreaInset(edge: .bottom, spacing: 0) { SubscriptionDebugEntry() }
        #endif
        // Always visible and never delayed, so leaving is as easy as buying.
        .overlay(alignment: .topTrailing) { closeButton }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !trackedView else { return }
            trackedView = true
            ProductAnalytics.shared.track(.paywallViewed)
        }
        .task { await arrive() }
        .task {
            await subscriptions.refreshEntitlements()
            await subscriptions.loadProducts()
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .onChange(of: subscriptions.isPro) { _, active in
            // Keep the paywall's presenting view alive until Apple's redemption
            // sheet has completed, then resume the requested replay tool.
            if active && !redeemingInvite { deliverUnlock() }
        }
        .onChange(of: managing) { _, value in
            if !value { Task { await subscriptions.refreshEntitlements() } }
        }
        .sensoryFeedback(.selection, trigger: plan)
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pro-paywall")
        .accessibilityAction(.escape, close)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .appGlass(in: .circle, interactive: true)
        .padding(.trailing, 16).padding(.top, 6)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("pro-close")
    }

    private func close() {
        // Dismiss the actual presentation as well as clearing its owner's state.
        // Direct review screens use onClose to return to the app instead.
        dismiss()
        onClose()
    }

    private var features: some View {
        HStack(spacing: 8) {
            ForEach(Array(ProFeature.allCases.enumerated()), id: \.element) { index, feature in
                ProFeatureTile(feature: feature, appeared: appeared)
                    .sessionEntrance(appeared, order: 5 + index, offset: 18)
            }
        }
    }

    private var plans: some View {
        HStack(spacing: 10) {
            ForEach(ProPlan.allCases) { option in
                // An active subscriber's verified plan takes precedence over the
                // default offer selection. Plan changes happen in Apple's sheet.
                ProPlanCard(plan: option, offer: subscriptions.offer(for: option),
                            selected: option == (subscriptions.activePlan ?? plan),
                            active: option == subscriptions.activePlan) {
                    if subscriptions.isPro { managing = true }
                    else { withAnimation(SessionMotion.snap) { plan = option } }
                }
                .accessibilityHint(subscriptions.isPro
                    ? "Opens Apple’s subscription settings to change your plan."
                    : "Selects this plan for purchase.")
            }
        }
        .disabled(working || !subscriptions.hasCheckedAccess)
        .sessionEntrance(appeared, order: 8, offset: 18)
    }

    private var purchase: some View {
        Button(action: buy) {
            ZStack {
                if working || (!subscriptions.isPro && subscriptions.checkingAccountAccess) || subscriptions.loading && offer == nil {
                    ProgressView().tint(ProPass.ink).transition(.sessionPop(scale: 0.4))
                } else {
                    Text(subscriptions.isPro ? String(localized: "Manage Pro subscription", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : offer.map { plan.buyLabel(price: $0.price) } ?? String(localized: "Plans unavailable", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
                        .contentTransition(.numericText())
                        .transition(.sessionPop(scale: 0.9))
                }
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(ProPass.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(ProPass.lime, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(SessionPressStyle(scale: 0.97))
        .disabled(working || !subscriptions.hasCheckedAccess || (!subscriptions.isPro && (offer == nil || subscriptions.checkingAccountAccess)))
        .sessionEntrance(appeared, order: 9, offset: 18, scale: 0.96)
        .accessibilityIdentifier("pro-purchase")
    }

    private var links: some View {
        HStack(spacing: 6) {
            link("Restore purchases", id: "pro-restore") { restore() }
                .disabled(working)
            Text("·").accessibilityHidden(true)
            link("Terms of Use", id: "pro-terms") { openURL(LegalLinks.terms) }
            Text("·").accessibilityHidden(true)
            link("Privacy Policy", id: "pro-privacy") { openURL(LegalLinks.privacy) }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.75))
        .minimumScaleFactor(0.8)
        .lineLimit(1)
    }

    private func link(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).underline() }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityIdentifier(id)
    }

    private func arrive() async {
        guard !appeared else { return }
        try? await Task.sleep(for: .milliseconds(60))
        appeared = true

    }

    private func buy() {
        if subscriptions.isPro { managing = true; return }
        guard !subscriptions.busy else { return }
        let purchasedPlan = plan
        ProductAnalytics.shared.track(.purchaseStarted(purchasedPlan))
        Task {
            do {
                switch try await subscriptions.purchase(purchasedPlan, accountID: account.user?.id) {
                case .purchased:
                    ProductAnalytics.shared.track(.purchaseFinished(purchasedPlan, .completed))
                    if onUnlocked != nil { deliverUnlock() }
                    else { close() }
                case .cancelled:
                    ProductAnalytics.shared.track(.purchaseFinished(purchasedPlan, .cancelled))
                case .pending:
                    ProductAnalytics.shared.track(.purchaseFinished(purchasedPlan, .pending))
                    notice = .init(title: String(localized: "Waiting for approval", bundle: AppLanguage.bundle, locale: AppLanguage.locale), message: String(localized: "Apple is processing this purchase. Pro will activate automatically when it’s approved. You can keep using the app.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
                }
            } catch {
                if let storeError = error as? StoreKitError, case .userCancelled = storeError {
                    ProductAnalytics.shared.track(.purchaseFinished(purchasedPlan, .cancelled))
                    return
                }
                ProductAnalytics.shared.track(.purchaseFinished(purchasedPlan, .failed))
                notice = .init(title: String(localized: "Purchase couldn’t complete", bundle: AppLanguage.bundle, locale: AppLanguage.locale), message: (error as? SubscriptionFailure)?.errorDescription ?? String(localized: "Please try again. If you already purchased Pro, use Restore purchases.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            }
        }
    }

    private func deliverUnlock() {
        guard subscriptions.isPro, let onUnlocked, !deliveredUnlock else { return }
        deliveredUnlock = true
        onUnlocked()
    }

    private func restore() {
        Task {
            do {
                let restored = try await subscriptions.restore()
                if restored && onUnlocked != nil { deliverUnlock(); return }
                notice = .init(title: restored ? String(localized: "Pro restored", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "No active subscription", bundle: AppLanguage.bundle, locale: AppLanguage.locale),
                               message: restored ? String(localized: "Your Juggle Dude Pro subscription is active.", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : String(localized: "No active Pro subscription was found for this Apple Account.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            } catch {
                if let storeError = error as? StoreKitError, case .userCancelled = storeError { return }
                notice = .init(title: String(localized: "Restore couldn’t complete", bundle: AppLanguage.bundle, locale: AppLanguage.locale), message:
                    (error as? SubscriptionFailure)?.errorDescription ?? (subscriptions.isPro
                        ? String(localized: "Your Pro access is still active. Apple couldn’t refresh your purchase history. You can keep using Pro and try Restore again later.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                        : String(localized: "Apple couldn’t refresh your purchase history. Check your connection and the Apple Account used to subscribe, then try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)))
            }
        }
    }
}

enum ProPass {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.04)
    static let card = Color(red: 0.075, green: 0.09, blue: 0.09)
    static let lime = TrainingHomeStyle.lime
    static let ink = TrainingHomeStyle.buttonInk
    static func display(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .largeTitle) }
}

private struct ProNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Hero

/// Intrinsic vertical layout keeps every preview above the text and purchase
/// choices, including on short screens and with larger accessibility text.
private struct ProPassHero: View {
    let appeared: Bool
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 14) {
            Text("JUGGLE DUDE \(Text("PRO").foregroundColor(ProPass.lime))")
                .font(.caption.weight(.heavy)).tracking(1.6)
                .padding(.horizontal, 44)
                .sessionEntrance(appeared, order: 1, offset: -8)
            ProSkinShowcase()
                .frame(height: 104)
                .sessionEntrance(appeared, order: 2, offset: 10)
            VStack(spacing: 8) {
                VStack(spacing: -9) {
                    Text("MAKE EVERY")
                    Text("REPLAY YOURS")
                }
                .font(ProPass.display(44))
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Effects, overlays and\nshot camera tools.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .sessionEntrance(appeared, order: 3, offset: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, topInset + 16)
        .padding(.bottom, 22)
        .background {
            LinearGradient(colors: [Color(red: 0.055, green: 0.095, blue: 0.065), ProPass.background],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .accessibilityIdentifier("pro-hero")
    }
}

/// 256px lossless snapshots from the production renderer: no material decoding,
/// model, Metal setup, timer, video playback or continuously animated preview.
private struct ProSkinShowcase: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [ProPass.lime.opacity(0.15), .clear],
                           center: .center, startRadius: 12, endRadius: 145)
                .frame(width: 290, height: 290)
                .scaleEffect(x: 1, y: 104.0 / 290.0)
                .frame(width: 290, height: 104)
            ProSquiggle()
                .stroke(ProPass.lime.opacity(0.32), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 276, height: 45)
            HStack(spacing: 24) {
                Image("pro-skin-stealth").resizable().scaledToFit()
                    .frame(width: 68, height: 68).offset(y: 9)
                Image("pro-skin-gold").resizable().scaledToFit()
                    .frame(width: 84, height: 84)
                Image("pro-skin-volt").resizable().scaledToFit()
                    .frame(width: 68, height: 68).offset(y: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Below the hero

private struct ProFeatureTile: View {
    let feature: ProFeature
    let appeared: Bool

    var body: some View {
        VStack(spacing: 8) {
            icon.frame(height: 30)
            Text(feature.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2).minimumScaleFactor(0.9)
                .multilineTextAlignment(.center)
                .frame(minHeight: 30)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 84)
        .background(ProPass.card, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch feature {
        case .effects:
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(ProPass.lime)
                .symbolEffect(.bounce, value: appeared)
        case .balls:
            Image(systemName: "soccerball")
                .font(.system(size: 27, weight: .regular))
                .rotationEffect(.degrees(appeared ? 360 : 0))
                .animation(.spring(response: 0.9, dampingFraction: 0.7).delay(0.6), value: appeared)
        case .motion:
            ProSquiggle()
                .trim(from: 0, to: appeared ? 1 : 0)
                .stroke(ProPass.lime, style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
                .frame(width: 40, height: 20)
                .animation(.easeOut(duration: 0.7).delay(0.7), value: appeared)
        }
    }
}

private struct ProSquiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.2))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.midY),
                      control1: CGPoint(x: rect.width * 0.18, y: rect.minY - rect.height * 0.3),
                      control2: CGPoint(x: rect.width * 0.32, y: rect.maxY + rect.height * 0.2))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.2),
                      control1: CGPoint(x: rect.width * 0.68, y: rect.minY - rect.height * 0.4),
                      control2: CGPoint(x: rect.width * 0.82, y: rect.maxY + rect.height * 0.1))
        return path
    }
}

private struct ProPlanCard: View {
    let plan: ProPlan
    let offer: ProOffer?
    let selected: Bool
    let active: Bool
    let action: () -> Void
    private var badge: String? { active ? String(localized: "Current plan", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : offer?.badge }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plan.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? ProPass.lime : .white.opacity(0.8))
                    Spacer(minLength: 4)
                    radio
                }
                // The billed amount leads; anything per month stays secondary.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(offer?.price ?? "—").font(.title3.weight(.bold)).monospacedDigit()
                    Text(plan.perPeriod).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                }
                Text(offer?.perMonth ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProPass.card, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? ProPass.lime : .white.opacity(0.12), lineWidth: selected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(ProPass.ink)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(ProPass.lime, in: .capsule)
                        .offset(x: -40, y: -10)
                }
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(SessionPressStyle(scale: 0.97))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([plan.title, offer.map { plan.spokenPrice($0.price) } ?? String(localized: "Price unavailable", bundle: AppLanguage.bundle, locale: AppLanguage.locale), badge]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("pro-plan-\(plan.rawValue)")
    }

    private var radio: some View {
        ZStack {
            Circle().strokeBorder(selected ? ProPass.lime : .white.opacity(0.5), lineWidth: 1.6)
            Circle().fill(ProPass.lime).padding(4)
                .scaleEffect(selected ? 1 : 0.01)
                .opacity(selected ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
    }
}

#Preview("Pro paywall") {
    ProPaywallView(onClose: {})
        .environmentObject(SubscriptionStore(observeTransactions: false))
        .environmentObject(AccountStore(service: nil))
}
