import AuthenticationServices
import SwiftUI

/// The first launch and Profile show this same main sign-in view; from Profile the guest
/// choice reads "Not now" and returns to Home. Every choice lives in one glass tray that grows
/// into the email steps, so nothing opens on top of it. Provider authorization is intentionally
/// separate from entering as a guest.
struct SignInView: View {
    enum Presentation { case welcome, profile }
    let presentation: Presentation
    let onContinueWithoutAccount: () -> Void
    @EnvironmentObject private var account: AccountStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var step = SignInStep.choose
    @State private var forward = true
    @State private var trayHeight: CGFloat = 0
    @State private var email = ""
    @State private var tapped: SignInProvider?
    @State private var arrived = false
    @State private var hops = 0
    @State private var signedIn = false
    @FocusState private var emailFocused: Bool

    private var accent: Color { TrainingHomeStyle.accent(scheme) }
    private var muted: Color { TrainingHomeStyle.muted(scheme) }
    private var validEmail: Bool { AccountConfiguration.normalizedEmail(email) != nil }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    wordmark
                        .padding(.top, 8).padding(.horizontal, 28)
                        .sessionEntrance(arrived, offset: -10)
                    SignInBallHero(arrived: arrived, busy: tapped != nil && account.isBusy,
                                   kicked: signedIn, hops: hops)
                        .frame(height: heroHeight(geometry.size.height))
                    if step == .choose || signedIn {
                        intro.padding(.horizontal, 28).transition(.blurReplace)
                    }
                    Spacer(minLength: 16)
                    tray.padding(.horizontal, 10).padding(.bottom, 6)
                }
                .frame(maxWidth: 460)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { backdrop }
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .tint(accent)
        .accessibilityIdentifier(presentation == .welcome ? "signin-welcome" : "signin-from-profile")
        .task { await arrive() }
        .onChange(of: account.user) { _, user in
            if user != nil { celebrate() }
        }
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.success, trigger: signedIn)
    }

    // MARK: - Above the tray

    /// Light under the tray gives the glass something to bend.
    private var backdrop: some View {
        ZStack(alignment: .bottom) {
            TrainingHomeStyle.background(scheme)
            Ellipse()
                .fill(accent.opacity(scheme == .dark ? 0.16 : 0.14))
                .frame(width: 520, height: 300)
                .blur(radius: 90)
                .offset(y: 120)
        }
        .ignoresSafeArea()
    }

    private var wordmark: some View {
        Text("\(Text("Juggle ").foregroundColor(TrainingHomeStyle.ink(scheme)))\(Text("Dude").foregroundColor(accent))")
            .font(TrainingHomeStyle.display(30, relativeTo: .title2)).tracking(0.8)
            .accessibilityLabel("Juggle Dude")
    }

    /// The ball steps back while the tray holds the email steps, and rides the keyboard down.
    private func heroHeight(_ available: CGFloat) -> CGFloat {
        if step != .choose && !signedIn { return min(140, max(76, available * 0.18)) }
        return typeSize.isAccessibilitySize ? 150 : min(240, max(140, available * 0.27))
    }

    private var intro: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text(signedIn ? "You’re in" : "Welcome to\nJuggle Dude"))\(Text(".").foregroundColor(accent))")
                    .font(TrainingHomeStyle.display(signedIn ? 64 : 52, relativeTo: .largeTitle))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.body).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(signedIn)
            .transition(.blurReplace)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sessionEntrance(arrived, order: 2)
    }

    private var subtitle: String {
        if signedIn { return account.user?.name.map { "Welcome, \($0)." } ?? "Let’s get juggling." }
        return presentation == .welcome ? "Sign in or start training as a guest." : "Sign in to keep your records safe."
    }

    // MARK: - Tray

    private var tray: some View {
        ZStack(alignment: .top) {
            switch step {
            case .choose: page(.choose) { choices }
            case .email: page(.email) { emailForm }
            case .sent: page(.sent) { sentNote }
            }
        }
        // The outgoing step never sizes the tray; it fades inside the new height.
        .frame(height: trayHeight > 0 ? trayHeight : nil, alignment: .top)
        .padding(18)
        .frame(maxWidth: .infinity)
        .mask { RoundedRectangle(cornerRadius: 34) }
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .offset(y: signedIn && !reduceMotion ? 640 : 0)
        .opacity(signedIn ? 0 : 1)
        .sessionEntrance(arrived, order: 3, offset: 36)
    }

    private func page<Content: View>(_ key: SignInStep, @ViewBuilder content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit($0, for: key) }
            .transition(swap)
    }

    /// Same swap as the Customize tray: the old step blurs out fast and the next one settles
    /// in sharp just behind it, leaning a few points in the direction of travel.
    private var swap: AnyTransition {
        if reduceMotion { return .opacity }
        let lean: CGFloat = forward ? 14 : -14
        return .asymmetric(
            insertion: .modifier(active: SignInTraySwap(hidden: true, lean: lean), identity: SignInTraySwap(hidden: false, lean: lean))
                .animation(.smooth(duration: 0.3).delay(0.05)),
            removal: .modifier(active: SignInTraySwap(hidden: true, lean: -lean * 0.6), identity: SignInTraySwap(hidden: false, lean: 0))
                .animation(.easeOut(duration: 0.14)))
    }

    private var choices: some View {
        VStack(spacing: 12) {
            AccountErrorBanner()
            SignInProviderButtons(busy: account.isBusy ? tapped : nil, onSelect: choose)
                .disabled(account.isBusy || account.isRestoring)
            if account.isRestoring {
                ProgressView("Restoring your session…")
                    .font(.footnote)
                    .accessibilityIdentifier("signin-progress")
            }
            Button(action: onContinueWithoutAccount) {
                HStack(spacing: 10) {
                    Text(presentation == .welcome ? "Try it first" : "Not now")
                    if presentation == .welcome {
                        Image(systemName: "arrow.right").font(.body.weight(.medium))
                    }
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SessionPressStyle(scale: 0.96))
            .disabled(account.isBusy)
            .foregroundStyle(presentation == .welcome ? accent : muted)
            .accessibilityIdentifier(presentation == .welcome ? "signin-guest" : "signin-not-now")
            legalLinks
        }
    }

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                backButton
                Text("Continue with email").font(.headline)
                Spacer(minLength: 0)
            }
            Text("We’ll email you a secure sign-in link. No password to remember.")
                .font(.subheadline).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("email-introduction")
            emailField
            AccountErrorBanner()
            sendButton
        }
    }

    private var emailField: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.body.weight(.medium))
                .foregroundStyle(validEmail ? accent : muted)
            TextField("Email address", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.go).focused($emailFocused)
                .accessibilityIdentifier("email-address")
                .onSubmit { if validEmail { send() } }
            if validEmail {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(accent)
                    .transition(.sessionPop(scale: 0.3))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .background(TrainingHomeStyle.panel(scheme), in: .capsule)
        .overlay {
            Capsule().strokeBorder(emailFocused ? accent.opacity(0.85) : TrainingHomeStyle.line(scheme),
                                   lineWidth: emailFocused ? 1.5 : 1)
        }
        .animation(SessionMotion.snap, value: validEmail)
        .animation(SessionMotion.fade, value: emailFocused)
    }

    /// Lights up lime once the address is valid; counts down while a resend is not allowed yet.
    private var sendButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = max(0, Int(ceil(account.resendAfter.timeIntervalSince(context.date))))
            let ready = validEmail && wait == 0 && !account.isBusy
            Button(action: send) {
                HStack(spacing: 10) {
                    if account.isBusy { ProgressView().tint(TrainingHomeStyle.buttonInk) }
                    Text(wait > 0 ? "Try again in \(wait)s" : "Send sign-in link")
                    if ready { Image(systemName: "arrow.right").transition(.sessionTuck(.leading)) }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(ready || account.isBusy ? TrainingHomeStyle.buttonInk : muted)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(ready || account.isBusy ? TrainingHomeStyle.lime : TrainingHomeStyle.line(scheme).opacity(0.6),
                            in: .capsule)
                .contentShape(.capsule)
                .animation(SessionMotion.snap, value: ready)
            }
            .buttonStyle(SessionPressStyle(scale: 0.97))
            .disabled(!ready)
            .accessibilityIdentifier("email-send")
        }
    }

    private var sentNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                backButton
                Text("Check your inbox\(Text(".").foregroundColor(accent))")
                    .font(TrainingHomeStyle.display(38, relativeTo: .title))
                    .accessibilityAddTraits(.isHeader)
            }
            Text("We sent a sign-in link to \(Text(account.pendingEmail ?? email).bold().foregroundColor(TrainingHomeStyle.ink(scheme))). Open it on this iPhone.")
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("email-sent-message")
            Text("Check Spam or Junk too. Only the newest link will work.")
                .font(.footnote).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            AccountErrorBanner()
            HStack(spacing: 12) {
                resendControl
                Spacer(minLength: 8)
                Button("Change email") {
                    account.errorMessage = nil
                    go(.email)
                }
                .font(.subheadline.weight(.semibold))
                .disabled(account.isBusy)
                .accessibilityIdentifier("email-change")
            }
            .frame(minHeight: 44)
        }
    }

    private var resendControl: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = max(0, Int(ceil(account.resendAfter.timeIntervalSince(context.date))))
            if wait > 0 {
                HStack(spacing: 10) {
                    ResendRing(progress: Double(wait) / 60)
                    Text("Resend in \(wait)s").monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(muted)
            } else {
                Button("Resend link", action: send)
                    .font(.subheadline.weight(.semibold))
                    .disabled(account.isBusy)
                    .accessibilityIdentifier("email-send")
            }
        }
    }

    private var backButton: some View {
        Button { go(.choose) } label: {
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .disabled(account.isBusy)
        .accessibilityLabel("Back to sign-in options")
        .accessibilityIdentifier("email-close")
    }

    private var legalLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                legalButton("Terms of Use", url: LegalLinks.terms, id: "signin-terms")
                Text("·").accessibilityHidden(true)
                legalButton("Privacy Policy", url: LegalLinks.privacy, id: "signin-privacy")
            }
            VStack(spacing: 0) {
                legalButton("Terms of Use", url: LegalLinks.terms, id: "signin-terms")
                legalButton("Privacy Policy", url: LegalLinks.privacy, id: "signin-privacy")
            }
        }
        .font(.caption)
        .foregroundStyle(muted)
        .frame(maxWidth: .infinity)
    }

    private func legalButton(_ title: String, url: URL, id: String) -> some View {
        Button(title) { openURL(url) }
            .buttonStyle(.plain).frame(minHeight: 44)
            .accessibilityIdentifier(id)
    }

    // MARK: - Actions

    private func arrive() async {
        if account.user != nil { onContinueWithoutAccount(); return }
        guard !arrived else { return }
        // On the first launch the opening halo covers the first moments.
        try? await Task.sleep(for: .milliseconds(presentation == .welcome ? 520 : 80))
        arrived = true
    }

    private func go(_ next: SignInStep) {
        guard next != step else { return }
        forward = next.rawValue > step.rawValue
        if next != .email { emailFocused = false }
        withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { step = next }
        // The tray starts growing first; the keyboard then lifts it the rest of the way.
        if next == .email {
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                emailFocused = true
            }
        }
    }

    private func choose(_ provider: SignInProvider) {
        account.errorMessage = nil
        guard provider != .email else {
            if let pending = account.pendingEmail { email = pending; go(.sent) } else { go(.email) }
            return
        }
        tapped = provider
        Task {
            await account.signIn(provider)
            tapped = nil
        }
    }

    private func send() {
        emailFocused = false
        Task {
            guard await account.sendEmailLink(to: email) else { return }
            go(.sent)
            hops += 1
        }
    }

    /// The tray sinks away and the ball is kicked toward Home before Home takes over.
    private func celebrate() {
        guard !signedIn else { return }
        emailFocused = false
        withAnimation(reduceMotion ? SessionMotion.fade : .smooth(duration: 0.55)) { signedIn = true }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 400 : 1100))
            onContinueWithoutAccount()
        }
    }

    /// Only the step being shown sets the height; the first measurement lands without animation.
    private func fit(_ height: CGFloat, for key: SignInStep) {
        guard key == step, abs(height - trayHeight) > 0.5 else { return }
        if trayHeight == 0 { trayHeight = height; return }
        withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { trayHeight = height }
    }
}

private enum SignInStep: Int { case choose, email, sent }

enum SignInProvider: String { case apple, google, email }

private struct SignInTraySwap: ViewModifier {
    let hidden: Bool
    let lean: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(hidden ? 0.97 : 1, anchor: .top)
            .offset(x: hidden ? lean : 0)
            .blur(radius: hidden ? 10 : 0)
            .opacity(hidden ? 0 : 1)
    }
}

private struct ResendRing: View {
    let progress: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().stroke(TrainingHomeStyle.line(scheme), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress)
                .stroke(TrainingHomeStyle.accent(scheme), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct SignInProviderButtons: View {
    /// The provider waiting on its own sheet; the other choices dim while it does.
    let busy: SignInProvider?
    let onSelect: (SignInProvider) -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var height = 54.0
    @ScaledMetric(relativeTo: .body) private var fontSize = 17.0
    @ScaledMetric(relativeTo: .subheadline) private var emailHeight = 46.0

    var body: some View {
        VStack(spacing: 12) {
            AppleAccountButton(outlined: scheme == .light) { onSelect(.apple) }
                .id(scheme)
                .frame(height: height)
                .overlay {
                    if busy == .apple { waiting("Waiting for Apple…").transition(.opacity) }
                }
                .opacity(dimmed(.apple) ? 0.35 : 1)
            Button { onSelect(.google) } label: {
                HStack(spacing: 12) {
                    if busy == .google {
                        ProgressView().tint(Color(red: 0.12, green: 0.12, blue: 0.12))
                        Text("Waiting for Google…")
                    } else {
                        Image("signin-google-mark").renderingMode(.original)
                            .resizable().scaledToFit().frame(width: 21, height: 21)
                        Text("Continue with Google")
                    }
                }
                .font(.system(size: fontSize, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(.white, in: .capsule)
                .overlay { Capsule().strokeBorder(Color(red: 0.45, green: 0.47, blue: 0.46), lineWidth: 1) }
                .contentShape(Capsule())
            }
            .buttonStyle(SessionPressStyle(scale: 0.97))
            .opacity(dimmed(.google) ? 0.35 : 1)
            .accessibilityIdentifier("signin-google")

            Button { onSelect(.email) } label: {
                Label("Continue with email", systemImage: "envelope")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TrainingHomeStyle.ink(scheme))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: emailHeight)
                    .background(TrainingHomeStyle.ink(scheme).opacity(0.05), in: .capsule)
                    .overlay { Capsule().strokeBorder(TrainingHomeStyle.line(scheme), lineWidth: 1) }
                    .contentShape(Capsule())
            }
            .buttonStyle(SessionPressStyle(scale: 0.97))
            .opacity(dimmed(.email) ? 0.35 : 1)
            .accessibilityIdentifier("signin-email")
        }
        .animation(SessionMotion.fade, value: busy)
    }

    private func dimmed(_ provider: SignInProvider) -> Bool { busy != nil && busy != provider }

    /// Covers Apple's control only while its sheet is up, so the wait reads in place.
    private func waiting(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(.black)
            Text(title).font(.system(size: fontSize, weight: .medium))
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white, in: .capsule)
        .overlay { if scheme == .light { Capsule().strokeBorder(.black, lineWidth: 1) } }
        .allowsHitTesting(false)
    }
}

/// Apple's own control preserves the provider's logo, title and sizing.
/// Uses the same native authorization flow from both account entry points.
private struct AppleAccountButton: UIViewRepresentable {
    let outlined: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: outlined ? .whiteOutline : .white)
        button.cornerRadius = 32
        button.accessibilityIdentifier = "signin-apple"
        button.addTarget(context.coordinator, action: #selector(Coordinator.select), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func select() { action() }
    }
}

// MARK: - The ball

/// Drops in and bounces on arrival, then idles with a slow bob. Spins while a provider
/// is confirming, hops when a link is sent, and is kicked away once signed in.
private struct SignInBallHero: View {
    let arrived: Bool
    let busy: Bool
    let kicked: Bool
    let hops: Int
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinStart: Date?

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.height, geometry.size.width * 0.87)
            let travel = geometry.size.height + diameter
            ZStack {
                Ellipse()
                    .fill(TrainingHomeStyle.accent(scheme).opacity(scheme == .dark ? 0.05 : 0.06))
                    .frame(width: diameter * 0.95, height: diameter * 0.7).blur(radius: 32)
                SignInFlightCurve()
                    .trim(from: 0, to: arrived ? 1 : 0)
                    .stroke(TrainingHomeStyle.accent(scheme).opacity(0.72), lineWidth: 0.7)
                    .animation(reduceMotion ? SessionMotion.fade : .easeInOut(duration: 1).delay(0.3), value: arrived)
                KickRings(kicked: kicked, diameter: diameter)
                if busy && !reduceMotion {
                    SpinArcs(diameter: diameter).transition(.opacity)
                }
                // Spin and shrink in place first, so the kick always travels up and away.
                ball(diameter: diameter, travel: travel)
                    .rotationEffect(.degrees(kicked && !reduceMotion ? 160 : 0))
                    .scaleEffect(kicked && !reduceMotion ? 0.55 : 1)
                    .offset(x: kicked && !reduceMotion ? diameter * 0.9 : 0,
                            y: kicked && !reduceMotion ? -travel * 1.6 : 0)
                    .opacity(arrived && !(kicked && reduceMotion) ? 1 : 0)
                    .animation(reduceMotion ? SessionMotion.fade : .easeIn(duration: 0.55), value: kicked)
                    .animation(SessionMotion.fade, value: arrived)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(SessionMotion.fade, value: busy)
        }
        .accessibilityHidden(true)
        .onChange(of: busy) { _, busy in spinStart = busy && !reduceMotion ? .now : nil }
    }

    private func ball(diameter: CGFloat, travel: CGFloat) -> some View {
        KeyframeAnimator(initialValue: BallBounce(), trigger: reduceMotion ? false : arrived) { drop in
            KeyframeAnimator(initialValue: BallBounce(), trigger: reduceMotion ? 0 : hops) { hop in
                TimelineView(.animation(paused: reduceMotion || !arrived || kicked)) { context in
                    SignInBall(diameter: diameter,
                               lift: idleLift(context.date, diameter: diameter) - drop.y - hop.y,
                               squash: drop.squash + hop.squash,
                               angle: idleAngle(context.date) + drop.angle + hop.angle,
                               grounded: !kicked)
                }
            } keyframes: { value in
                KeyframeTrack(\.y) {
                    LinearKeyframe(-diameter * 0.32, duration: 0.24, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.22, timingCurve: .easeIn)
                    LinearKeyframe(-diameter * 0.07, duration: 0.1, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.1, timingCurve: .easeIn)
                }
                KeyframeTrack(\.squash) {
                    LinearKeyframe(-0.06, duration: 0.1)
                    LinearKeyframe(0, duration: 0.34)
                    LinearKeyframe(0.1, duration: 0.04)
                    SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.angle) {
                    LinearKeyframe(value.angle + 360, duration: 0.56, timingCurve: .easeInOut)
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.y) {
                MoveKeyframe(-travel)
                LinearKeyframe(0, duration: 0.46, timingCurve: .easeIn)
                LinearKeyframe(-diameter * 0.16, duration: 0.2, timingCurve: .easeOut)
                LinearKeyframe(0, duration: 0.2, timingCurve: .easeIn)
                LinearKeyframe(-diameter * 0.04, duration: 0.1, timingCurve: .easeOut)
                LinearKeyframe(0, duration: 0.1, timingCurve: .easeIn)
            }
            KeyframeTrack(\.squash) {
                LinearKeyframe(0, duration: 0.44)
                LinearKeyframe(0.14, duration: 0.04)
                SpringKeyframe(0, duration: 0.36, spring: .bouncy)
                LinearKeyframe(0.05, duration: 0.04)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                MoveKeyframe(-160)
                LinearKeyframe(0, duration: 0.9, timingCurve: .easeOut)
            }
        }
    }

    /// A slow bob that never dips into the floor.
    private func idleLift(_ date: Date, diameter: CGFloat) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let wave = sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 2.8)
        return CGFloat(1 + wave) * diameter * 0.022
    }

    private func idleAngle(_ date: Date) -> Double {
        guard !reduceMotion else { return 0 }
        let rock = sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 5.6) * 3
        guard let spinStart else { return rock }
        return rock + date.timeIntervalSince(spinStart) * 520
    }
}

private struct BallBounce {
    /// Points; negative is up.
    var y: CGFloat = 0
    /// 0 is round; positive flattens against the floor, negative stretches.
    var squash: CGFloat = 0
    var angle: Double = 0
}

private struct SignInBall: View {
    let diameter: CGFloat
    /// Points above the floor.
    let lift: CGFloat
    let squash: CGFloat
    let angle: Double
    /// The shadow leaves with the ball when it is kicked.
    var grounded = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let height = min(1, max(0, lift / (diameter * 1.2)))
        ZStack {
            Ellipse()
                .fill(.black.opacity((scheme == .dark ? 0.4 : 0.12) * (1 - height * 0.7) * (grounded ? 1 : 0)))
                .frame(width: diameter * 0.68 * (1 - height * 0.45), height: 14)
                .blur(radius: 12)
                .offset(y: diameter * 0.40)
            Image("signin-ball").resizable().scaledToFit()
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(angle))
                .scaleEffect(x: 1 + squash, y: 1 - squash, anchor: .bottom)
                .offset(y: -lift)
        }
    }
}

/// Two lime arcs circling the ball while Apple or Google confirms.
private struct SpinArcs: View {
    let diameter: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().trim(from: 0.02, to: 0.22)
                    .stroke(TrainingHomeStyle.accent(scheme), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle().trim(from: 0.52, to: 0.68)
                    .stroke(TrainingHomeStyle.accent(scheme).opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(width: diameter * 1.12, height: diameter * 1.12)
            .rotationEffect(.degrees(turn))
        }
    }
}

/// Lime rings burst from the floor as the ball is kicked.
private struct KickRings: View {
    let kicked: Bool
    let diameter: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KeyframeAnimator(initialValue: RingBurst(), trigger: reduceMotion ? false : kicked) { burst in
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .strokeBorder(TrainingHomeStyle.accent(scheme).opacity(0.6 - Double(ring) * 0.15), lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(burst.scale * (1 + CGFloat(ring) * 0.3))
                }
            }
            .opacity(burst.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(0.6)
                LinearKeyframe(1.9, duration: 0.8, timingCurve: .easeOut)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(1)
                LinearKeyframe(0, duration: 0.8, timingCurve: .easeIn)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RingBurst {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

private struct SignInFlightCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -28, y: rect.height * 0.78))
        path.addCurve(to: CGPoint(x: rect.width + 28, y: rect.height * 0.18),
                      control1: CGPoint(x: rect.width * 0.25, y: rect.height * 0.48),
                      control2: CGPoint(x: rect.width * 0.72, y: rect.height * 0.63))
        return path
    }
}
