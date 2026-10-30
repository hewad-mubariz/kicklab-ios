import SwiftUI
import StoreKit

/// Juggle Dude Pro, the "Pro Pass" direction: the juggler cut out over a lime slash, a touch
/// counter that ticks up along its motion line, then the plans.
///
/// Built with App Review in mind: an always-visible close button, the billed price as the
/// strongest price, renewal terms beside the button, and Restore, Terms and Privacy links.
struct ProPaywallView: View {
    let onClose: () -> Void
    var onUnlocked: (() -> Void)? = nil
    @State private var deliveredUnlock = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan = ProPlan.yearly
    @State private var appeared = false
    @State private var trackedView = false
    @State private var touches = 0
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openURL) private var openURL
    @State private var managing = false
    private var working: Bool { subscriptions.busy }
    private var offer: ProOffer? { subscriptions.offer(for: plan) }
    @State private var notice: ProNotice?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ProPassHero(appeared: appeared, touches: touches, topInset: proxy.safeAreaInsets.top)
                        .frame(height: heroHeight(proxy))
                    VStack(spacing: 12) {
                        features
                        Text("Recording, basic replays and basic export stay free.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pro-free-features")
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
                    .padding(.top, -34)
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
            if active { deliverUnlock() }
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

    /// The hero takes whatever the plans and terms leave, so tall phones fill the screen
    /// and small ones scroll.
    private func heroHeight(_ proxy: GeometryProxy) -> CGFloat {
        let screen = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        return max(400, screen - 418)
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
        guard !reduceMotion else { touches = 5; return }
        // The counter ticks up as the motion line draws toward the ball.
        try? await Task.sleep(for: .milliseconds(900))
        for count in 1...5 {
            withAnimation(.snappy(duration: 0.2)) { touches = count }
            try? await Task.sleep(for: .milliseconds(230))
        }
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

/// The photo dimmed behind, a lime slash sweeping down, the juggler cut out in front of it,
/// the headline on the left and a touch counter with its motion line running to the ball.
private struct ProPassHero: View {
    let appeared: Bool
    let touches: Int
    let topInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            // The photo is 2:3 with the juggler centred; place them at two-thirds across.
            let photo = CGSize(width: w * 1.22, height: w * 1.22 * 1.5)
            let origin = CGPoint(x: w * 0.73 - photo.width / 2, y: topInset - photo.height * 0.08)
            let ball = CGPoint(x: origin.x + photo.width * 0.62, y: origin.y + photo.height * 0.525)
            ZStack(alignment: .topLeading) {
                layer(w, h) {
                    Image("home-juggling").resizable()
                        .frame(width: photo.width, height: photo.height)
                        .saturation(0.75).brightness(-0.25)
                        .scaleEffect(appeared || reduceMotion ? 1 : 1.08)
                        .animation(reduceMotion ? nil : .easeOut(duration: 2.6), value: appeared)
                        .offset(x: origin.x, y: origin.y)
                }
                ProSlash()
                    .fill(LinearGradient(colors: [ProPass.lime, ProPass.lime.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .scaleEffect(x: 1, y: appeared || reduceMotion ? 1 : 0, anchor: .top)
                    .animation(reduceMotion ? SessionMotion.fade : .spring(response: 0.55, dampingFraction: 0.82).delay(0.12), value: appeared)
                layer(w, h) {
                    Image("pro-hero-player").resizable()
                        .frame(width: photo.width, height: photo.height)
                        .shadow(color: .black.opacity(0.5), radius: 16, x: -8, y: 10)
                        .offset(x: origin.x, y: origin.y + (appeared || reduceMotion ? 0 : 22))
                        .opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? SessionMotion.fade : .spring(response: 0.6, dampingFraction: 0.8).delay(0.22), value: appeared)
                }
                // Legible headline on the left, and a soft fade into the page below.
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.6, y: 0.5))
                LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: ProPass.background, location: 0.97)],
                               startPoint: .top, endPoint: .bottom)
                ProMotionLine(start: CGPoint(x: 92, y: h * 0.72), end: CGPoint(x: ball.x - 22, y: ball.y + 4), progress: Double(touches) / 5)
                    .opacity(appeared ? 1 : 0)
                headline
                    .padding(.leading, 20)
                    .padding(.top, topInset + 26)
                ProTouchBadge(touches: touches)
                    .position(x: 52, y: h * 0.72)
                    .sessionEntrance(appeared, order: 4, scale: 0.6)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
        }
    }

    /// A full-size layer whose content can sit anywhere without changing the hero's size.
    private func layer<Content: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        Color.clear.frame(width: w, height: h).overlay(alignment: .topLeading, content: content)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("JUGGLE DUDE \(Text("PRO").foregroundColor(ProPass.lime))")
                .font(.caption.weight(.heavy)).tracking(1.6)
                .sessionEntrance(appeared, order: 1, offset: -10)
            VStack(alignment: .leading, spacing: -14) {
                Text("MAKE EVERY")
                Text("REPLAY YOURS")
            }
            .font(ProPass.display(58))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.16, d: 1, tx: 8, ty: 0))
            .padding(.top, 12)
            .sessionEntrance(appeared, order: 2, offset: -14)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Effects, overlays and\nshot camera tools.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 2)
                .sessionEntrance(appeared, order: 3, offset: -8)
        }
    }
}

/// A broad lime brush-slash behind the juggler, with a thin echo beside it.
private struct ProSlash: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.8, y: h * 0.05))
        path.addLine(to: CGPoint(x: w * 1.06, y: h * 0.05))
        path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.6, y: h * 0.84))
        path.closeSubpath()
        path.move(to: CGPoint(x: w * 1.04, y: h * 0.3))
        path.addLine(to: CGPoint(x: w * 1.04, y: h * 0.38))
        path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.86))
        path.addLine(to: CGPoint(x: w * 0.8, y: h * 0.86))
        path.closeSubpath()
        return path
    }
}

private struct ProTouchBadge: View {
    let touches: Int

    var body: some View {
        VStack(spacing: -4) {
            Text(String(format: "%02d", touches))
                .font(ProPass.display(40))
                .contentTransition(.numericText(value: Double(touches)))
                .padding(.top, 6)
            Text("TOUCHES").font(.system(size: 9, weight: .heavy)).tracking(1)
        }
        .frame(width: 68, height: 68)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.75), lineWidth: 1.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(touches) touches")
    }
}

/// The juggle as a lime motion line: one hop per touch, drawn as the counter ticks.
private struct ProMotionLine: View {
    let start: CGPoint
    let end: CGPoint
    let progress: Double

    var body: some View {
        let path = Self.hops(from: start, to: end)
        ZStack {
            path.trim(from: 0, to: progress)
                .stroke(ProPass.lime.opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .blur(radius: 5)
            path.trim(from: 0, to: progress)
                .stroke(ProPass.lime, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            Circle().fill(ProPass.lime)
                .frame(width: 9, height: 9)
                .shadow(color: ProPass.lime, radius: 6)
                .position(start)
        }
        .animation(.easeOut(duration: 0.22), value: progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func hops(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let count = 5
        for index in 0..<count {
            let t0 = CGFloat(index) / CGFloat(count), t1 = CGFloat(index + 1) / CGFloat(count)
            let a = CGPoint(x: start.x + (end.x - start.x) * t0, y: start.y + (end.y - start.y) * t0)
            let b = CGPoint(x: start.x + (end.x - start.x) * t1, y: start.y + (end.y - start.y) * t1)
            let lift: CGFloat = 26 + CGFloat(index % 2) * 12
            path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift))
        }
        return path
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
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
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
