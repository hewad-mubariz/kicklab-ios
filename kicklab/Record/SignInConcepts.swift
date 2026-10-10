#if DEBUG
import SwiftUI

/// Sign-in directions, for review only. Launch with
/// --session-design signin-concept --concept A|B|C|S --signin-state <state>.
struct SignInConceptView: View {
    let concept: String
    let state: String

    var body: some View {
        ZStack {
            Look.bg.ignoresSafeArea()
            switch concept {
            case "B": TrayConcept(state: state)
            case "C": ScoreboardConcept(state: state)
            case "S": SharedConcept(state: state)
            default: MorphConcept(state: state)
            }
        }
        .foregroundStyle(Look.ink)
        .preferredColorScheme(.dark)
    }
}

/// Runs the real sign-in view against a stand-in account service, so every step can be
/// reviewed without sending email or opening Apple or Google. Launch with --session-design signin-demo.
struct SignInDemo: View {
    @StateObject private var account = AccountStore(service: DemoAccountService())
    @State private var entered = false

    var body: some View {
        Group {
            if entered {
                HomeView(personalBest: 11, onJuggling: {}, onPowerShot: {}, onImport: {}, onProfile: {}, onSetupGuide: {})
            } else {
                SignInView(presentation: .welcome) { entered = true }
            }
        }
        .animation(.smooth(duration: 0.4), value: entered)
        .environmentObject(account)
    }
}

/// Apple and Google answer after a short wait; a sent link is "opened" a few seconds later.
@MainActor
private final class DemoAccountService: AccountAuthService {
    let changes: AsyncStream<AccountIdentity?>
    private let continuation: AsyncStream<AccountIdentity?>.Continuation
    private let person = AccountIdentity(id: UUID(), email: "jules@example.com", name: "Jules")

    init() {
        let (changes, continuation) = AsyncStream<AccountIdentity?>.makeStream()
        self.changes = changes
        self.continuation = continuation
        continuation.yield(nil)
    }

    func google() async throws -> AccountIdentity { try await Task.sleep(for: .seconds(1.8)); return person }
    func apple() async throws -> AccountIdentity { try await Task.sleep(for: .seconds(1.8)); return person }
    func sendLink(email: String) async throws {
        try await Task.sleep(for: .seconds(0.8))
        let person = person
        let continuation = continuation
        Task {
            try? await Task.sleep(for: .seconds(4))
            continuation.yield(person)
        }
    }
    func callback(_ url: URL) async throws -> AccountIdentity { person }
    func signOut() async throws { continuation.yield(nil) }
    func setActive(_ active: Bool) async {}
}

private enum Look {
    static let bg = TrainingHomeStyle.background(.dark)
    static let panel = TrainingHomeStyle.panel(.dark)
    static let ink = TrainingHomeStyle.ink(.dark)
    static let muted = TrainingHomeStyle.muted(.dark)
    static let line = TrainingHomeStyle.line(.dark)
    static let lime = TrainingHomeStyle.lime
    static let buttonInk = TrainingHomeStyle.buttonInk
    static let sample = "jules@example.com"
    static func display(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .largeTitle) }
}

// MARK: - Shared pieces

private struct Wordmark: View {
    var size: CGFloat = 30
    var body: some View {
        Text("Juggle \(Text("Dude").foregroundColor(Look.lime))")
            .font(Look.display(size)).tracking(0.8)
    }
}

private struct Headline: View {
    let text: String
    var size: CGFloat = 52
    var body: some View {
        Text("\(Text(text))\(Text(".").foregroundColor(Look.lime))")
            .font(Look.display(size))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Ball: View {
    let size: CGFloat
    var lift: CGFloat = 0
    var spin: Double = 0
    var shadow = true

    var body: some View {
        ZStack {
            if shadow {
                Ellipse().fill(.black.opacity(0.55))
                    .frame(width: size * (0.62 - lift * 0.3), height: size * 0.08)
                    .blur(radius: size * 0.05)
                    .offset(y: size * 0.47)
            }
            Image("signin-ball").resizable().scaledToFit()
                .frame(width: size, height: size)
                .rotationEffect(.degrees(spin))
                .offset(y: -lift * size)
        }
        .frame(width: size, height: size)
    }
}

/// Faded copies of the ball along its path, standing in for motion in a still frame.
private struct Ghosts: View {
    let points: [CGPoint]
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(points.indices, id: \.self) { index in
                let t = Double(index + 1) / Double(points.count + 1)
                let side = size * (0.5 + 0.5 * t)
                Image("signin-ball").resizable().scaledToFit()
                    .frame(width: side, height: side)
                    .opacity(0.07 + 0.16 * t)
                    .position(points[index])
            }
        }
    }
}

private struct FlightCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -28, y: rect.height * 0.78))
        path.addCurve(to: CGPoint(x: rect.width + 28, y: rect.height * 0.18),
                      control1: CGPoint(x: rect.width * 0.25, y: rect.height * 0.48),
                      control2: CGPoint(x: rect.width * 0.72, y: rect.height * 0.63))
        return path
    }
}

/// A lime streak behind a ball in flight.
private struct Streak: Shape {
    let from: CGPoint
    let to: CGPoint
    let bend: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let control = CGPoint(x: (from.x + to.x) / 2 + bend, y: (from.y + to.y) / 2)
        path.addQuadCurve(to: to, control: control)
        return path
    }
}

private struct SpinArcs: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().trim(from: 0.02, to: 0.24)
                .stroke(Look.lime, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            Circle().trim(from: 0.52, to: 0.70)
                .stroke(Look.lime.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .frame(width: size * 1.12, height: size * 1.12)
        .rotationEffect(.degrees(-30))
    }
}

private enum Provider { case apple, google, email }

private struct ProviderButton: View {
    let provider: Provider
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().tint(Color(white: 0.1)).controlSize(.small)
                Text(provider == .apple ? "Waiting for Apple…" : "Waiting for Google…")
            } else {
                icon
                Text(title)
            }
        }
        .font(.system(size: provider == .email ? 15 : 17, weight: provider == .apple ? .semibold : .medium))
        .foregroundStyle(provider == .email ? Look.ink : Color(white: 0.08))
        .frame(maxWidth: .infinity)
        .frame(height: provider == .email ? 48 : 54)
        .background(provider == .email ? Color.clear : Color.white, in: .capsule)
        .overlay { Capsule().strokeBorder(provider == .email ? Look.line : .clear) }
    }

    @ViewBuilder private var icon: some View {
        switch provider {
        case .apple: Image(systemName: "apple.logo").font(.system(size: 19, weight: .medium)).offset(y: -1)
        case .google: Image("signin-google-mark").resizable().scaledToFit().frame(width: 20, height: 20)
        case .email: Image(systemName: "envelope").font(.system(size: 15, weight: .medium))
        }
    }

    private var title: String {
        switch provider {
        case .apple: "Continue with Apple"
        case .google: "Continue with Google"
        case .email: "Continue with email"
        }
    }
}

private struct MiniProvider: View {
    let provider: Provider
    var body: some View {
        HStack(spacing: 8) {
            if provider == .apple {
                Image(systemName: "apple.logo").font(.system(size: 16, weight: .medium)).offset(y: -1)
            } else {
                Image("signin-google-mark").resizable().scaledToFit().frame(width: 17, height: 17)
            }
            Text(provider == .apple ? "Apple" : "Google").font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(Color(white: 0.08))
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(.white, in: .capsule)
    }
}

private struct OtherProviders: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Rectangle().fill(Look.line).frame(height: 1)
                Text("or").font(.footnote).foregroundStyle(Look.muted)
                Rectangle().fill(Look.line).frame(height: 1)
            }
            HStack(spacing: 10) {
                MiniProvider(provider: .apple)
                MiniProvider(provider: .google)
            }
        }
    }
}

private struct BackChip: View {
    var symbol = "chevron.left"
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

private struct EmailField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var corner: CGFloat = 29

    private var valid: Bool { AccountConfiguration.normalizedEmail(text) != nil }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope").font(.system(size: 17, weight: .medium))
                .foregroundStyle(valid ? Look.lime : Look.muted)
            TextField("Email address", text: $text)
                .focused(focused)
                .keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tint(Look.lime)
            if valid {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                    .foregroundStyle(Look.lime)
            }
        }
        .font(.system(size: 18))
        .padding(.horizontal, 20).frame(height: 58)
        .background(Look.panel, in: .rect(cornerRadius: corner))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Look.lime.opacity(0.8), lineWidth: 1.5) }
    }
}

private struct LimeButton: View {
    let title: String
    var icon: String? = nil
    var enabled = true
    var trailingArrow = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon) }
            Text(title)
            if trailingArrow && enabled { Image(systemName: "arrow.right") }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(enabled ? Look.buttonInk : Look.muted)
        .frame(maxWidth: .infinity).frame(height: 54)
        .background(enabled ? Look.lime : Look.panel, in: .capsule)
    }
}

private struct ResendRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Look.line, lineWidth: 2.5)
                Circle().trim(from: 0, to: 0.7).stroke(Look.lime, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            Text("Resend in 0:42").foregroundStyle(Look.muted)
            Spacer()
            Text("Change email").foregroundStyle(Look.lime)
        }
        .font(.subheadline.weight(.medium))
    }
}

/// What the user should look for in their inbox, so the link is easy to find.
private struct InboxPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("signin-ball").resizable().scaledToFit().frame(width: 30, height: 30)
                    .padding(4).background(Look.bg, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Juggle Dude").font(.subheadline.weight(.semibold))
                    Text("Your sign-in link").font(.footnote).foregroundStyle(Look.muted)
                }
                Spacer()
                Text("now").font(.caption).foregroundStyle(Look.muted)
            }
            HStack(spacing: 8) {
                Text("Sign in to Juggle Dude").font(.footnote.weight(.semibold))
                Image(systemName: "arrow.right").font(.caption.weight(.bold))
            }
            .foregroundStyle(Look.buttonInk)
            .padding(.horizontal, 14).frame(height: 34)
            .background(Look.lime, in: .capsule)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.panel, in: .rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Look.line) }
    }
}

private struct Legal: View {
    var body: some View {
        Text("Terms of Use  ·  Privacy Policy")
            .font(.caption).foregroundStyle(Look.muted)
            .frame(maxWidth: .infinity).frame(height: 36)
    }
}

// MARK: - Welcome (shared by A, B's ending and the shared row)

private struct WelcomeScreen: View {
    enum Footer { case guest, notNow }
    var footer: Footer = .guest
    var busy: Provider? = nil
    var ghosts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Wordmark()
                Spacer()
                if footer == .notNow { BackChip(symbol: "xmark") }
            }
            .frame(height: 44)
            .padding(.top, 4)
            hero.frame(height: 250).padding(.vertical, 14)
            Headline(text: "Welcome to\nJuggle Dude")
            Text(footer == .guest ? "Sign in or start training as a guest." : "Sign in to keep your records safe.")
                .foregroundStyle(Look.muted).padding(.top, 8).padding(.bottom, 24)
            VStack(spacing: 12) {
                ProviderButton(provider: .apple, busy: busy == .apple)
                    .opacity(busy == nil || busy == .apple ? 1 : 0.3)
                ProviderButton(provider: .google, busy: busy == .google)
                    .opacity(busy == nil || busy == .google ? 1 : 0.3)
                ProviderButton(provider: .email)
                    .opacity(busy == nil ? 1 : 0.3)
            }
            footerButton.padding(.top, 12).opacity(busy == nil ? 1 : 0.3)
            Spacer(minLength: 8)
            Legal()
        }
        .padding(.horizontal, 28)
    }

    private var footerButton: some View {
        HStack(spacing: 10) {
            Text(footer == .guest ? "Try it first" : "Not now")
            if footer == .guest { Image(systemName: "arrow.right") }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(footer == .guest ? Look.lime : Look.muted)
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    private var hero: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.height, geometry.size.width * 0.87) * 0.9
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                Ellipse().fill(Look.lime.opacity(0.05))
                    .frame(width: size * 0.95, height: size * 0.7).blur(radius: 32)
                FlightCurve().stroke(Look.lime.opacity(0.7), lineWidth: 0.7)
                if ghosts {
                    Ghosts(points: [CGPoint(x: w * 1.02, y: -h * 0.12),
                                    CGPoint(x: w * 0.86, y: h * 0.06),
                                    CGPoint(x: w * 0.7, y: h * 0.3)], size: size * 0.8)
                }
                if busy != nil { SpinArcs(size: size) }
                Ball(size: size, lift: 0.03, spin: busy == nil ? 0 : 40)
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: - A · Morph in place

private struct MorphConcept: View {
    let state: String
    var body: some View {
        if state == "welcome" { WelcomeScreen(ghosts: true) } else { MorphEmail(state: state) }
    }
}

private struct MorphEmail: View {
    let state: String
    @State private var email = ""
    @FocusState private var focused: Bool

    private var sent: Bool { state == "sent" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BackChip()
                Spacer()
                Ball(size: 54, spin: 18, shadow: false)
            }
            .padding(.top, 4)
            Headline(text: sent ? "Check your\ninbox" : "Your email", size: 54).padding(.top, 18)
            if sent { sentBody } else { form }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .task {
            guard !sent else { return }
            email = state == "typed" ? Look.sample : ""
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("We’ll email you a sign-in link. No password.")
                .foregroundStyle(Look.muted).padding(.top, 8).padding(.bottom, 22)
            EmailField(text: $email, focused: $focused)
            LimeButton(title: "Send sign-in link", enabled: state == "typed", trailingArrow: true)
                .padding(.top, 12)
            OtherProviders().padding(.top, 20)
        }
    }

    private var sentBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("We sent a link to \(Text(Look.sample).foregroundColor(Look.ink).bold()). Open it on this iPhone.")
                .foregroundStyle(Look.muted).padding(.top, 10)
            InboxPreview().padding(.top, 26)
            LimeButton(title: "Open Mail", icon: "envelope.open").padding(.top, 22)
            ResendRow().padding(.top, 20)
        }
    }
}

// MARK: - B · Glass tray

private struct TrayConcept: View {
    let state: String
    @State private var email = Look.sample
    @FocusState private var focused: Bool

    private var open: Bool { state != "welcome" }

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop
            tray
                .padding(.horizontal, 10)
                .padding(.bottom, open && state != "sent" ? 6 : 2)
        }
        .task {
            guard state == "email" else { return }
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
    }

    private var backdrop: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Wordmark(); Spacer() }.frame(height: 44).padding(.top, 4)
            ZStack {
                Ellipse().fill(Look.lime.opacity(open ? 0.06 : 0.1))
                    .frame(width: open ? 220 : 330, height: open ? 160 : 240).blur(radius: 40)
                Ball(size: open ? 150 : 250)
            }
            .frame(height: open ? 200 : 320)
            if !open {
                Headline(text: "Welcome to\nJuggle Dude").padding(.top, 6)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder private var tray: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case "email":
                HStack {
                    BackChip()
                    Text("Continue with email").font(.headline)
                    Spacer()
                }
                EmailField(text: $email, focused: $focused)
                LimeButton(title: "Send sign-in link", trailingArrow: true)
            case "sent":
                Headline(text: "Check your inbox", size: 40).padding(.top, 4)
                Text("Link sent to \(Text(Look.sample).foregroundColor(Look.ink).bold())")
                    .foregroundStyle(Look.muted)
                LimeButton(title: "Open Mail", icon: "envelope.open").padding(.top, 6)
                ResendRow().padding(.vertical, 6)
            default:
                ProviderButton(provider: .apple)
                ProviderButton(provider: .google)
                ProviderButton(provider: .email)
                HStack(spacing: 10) { Text("Try it first"); Image(systemName: "arrow.right") }
                    .font(.body.weight(.medium)).foregroundStyle(Look.lime)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
    }
}

// MARK: - C · Scoreboard

private struct ScoreboardConcept: View {
    let state: String
    @State private var email = Look.sample
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { BackChip(); Spacer(); Wordmark(size: 22) }.padding(.top, 4)
            switch state {
            case "sending": sending
            case "sent": sent
            default: typing
            }
        }
        .padding(.horizontal, 28)
        .task {
            guard state == "email" else { return }
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR EMAIL").font(.caption.weight(.bold)).tracking(2.4)
                .foregroundStyle(Look.lime).padding(.top, 30)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text("jules@\nexample.com").font(Look.display(66)).lineSpacing(-6)
                RoundedRectangle(cornerRadius: 2).fill(Look.lime).frame(width: 5, height: 52)
            }
            .padding(.top, 10)
            TextField("", text: $email).focused($focused).keyboardType(.emailAddress)
                .foregroundStyle(.clear).tint(.clear).opacity(0.001).frame(height: 1)
            Text("We’ll send a sign-in link. No password.")
                .foregroundStyle(Look.muted).padding(.top, 12)
            Spacer()
            HStack(spacing: 14) {
                Spacer()
                Text("Kick to send").font(.subheadline.weight(.semibold)).foregroundStyle(Look.lime)
                ZStack {
                    Circle().strokeBorder(Look.lime, lineWidth: 2)
                    Ball(size: 64, shadow: false)
                }
                .frame(width: 82, height: 82)
            }
            .padding(.bottom, 12)
        }
    }

    private var sending: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SENDING").font(.caption.weight(.bold)).tracking(2.4).foregroundStyle(Look.lime)
                    Text("jules@example.com").font(Look.display(40)).foregroundStyle(Look.muted)
                }
                .padding(.top, 30)
                Streak(from: CGPoint(x: w * 0.82, y: h * 0.92), to: CGPoint(x: w * 0.62, y: h * 0.3), bend: 70)
                    .stroke(LinearGradient(colors: [Look.lime.opacity(0), Look.lime], startPoint: .bottom, endPoint: .top),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                Ghosts(points: [CGPoint(x: w * 0.86, y: h * 0.78), CGPoint(x: w * 0.78, y: h * 0.55)], size: 70)
                Ball(size: 74, spin: 60, shadow: false).position(x: w * 0.62, y: h * 0.28)
            }
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHECK YOUR INBOX").font(.caption.weight(.bold)).tracking(2.4)
                .foregroundStyle(Look.lime).padding(.top, 30)
            Headline(text: "Link\nsent", size: 118).lineSpacing(-14).padding(.top, 6)
            Text("to \(Text(Look.sample).foregroundColor(Look.ink).bold())")
                .foregroundStyle(Look.muted)
            Spacer()
            Ball(size: 132, lift: 0.04).frame(maxWidth: .infinity)
            Spacer()
            LimeButton(title: "Open Mail", icon: "envelope.open")
            ResendRow().padding(.vertical, 18)
        }
    }
}

// MARK: - Shared moments

private struct SharedConcept: View {
    let state: String
    var body: some View {
        switch state {
        case "busy": WelcomeScreen(busy: .apple)
        case "success": SuccessMoment()
        case "home": HomeLanding()
        case "profile": ProfileEntry()
        default: WelcomeScreen(footer: .notNow)
        }
    }
}

/// The provider says yes: the buttons sink away and the ball is kicked toward Home.
private struct SuccessMoment: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Wordmark(); Spacer() }.frame(height: 44).padding(.top, 4)
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                ZStack {
                    ForEach(0..<3, id: \.self) { ring in
                        Circle().strokeBorder(Look.lime.opacity(0.5 - Double(ring) * 0.15), lineWidth: 1.5)
                            .frame(width: 150 + CGFloat(ring) * 60, height: 150 + CGFloat(ring) * 60)
                            .position(x: w * 0.5, y: h * 0.72)
                    }
                    Streak(from: CGPoint(x: w * 0.5, y: h * 0.72), to: CGPoint(x: w * 0.86, y: h * 0.02), bend: -40)
                        .stroke(LinearGradient(colors: [Look.lime.opacity(0), Look.lime], startPoint: .bottom, endPoint: .top),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    Ghosts(points: [CGPoint(x: w * 0.56, y: h * 0.5), CGPoint(x: w * 0.68, y: h * 0.26)], size: 110)
                    Ball(size: 92, spin: 90, shadow: false).position(x: w * 0.86, y: h * 0.02)
                }
            }
            .frame(height: 250).padding(.vertical, 14)
            Headline(text: "You’re in", size: 72)
            Text("Welcome, Jules. Your records now follow you.")
                .foregroundStyle(Look.muted).padding(.top, 8)
            VStack(spacing: 12) {
                ProviderButton(provider: .apple)
                ProviderButton(provider: .google)
                ProviderButton(provider: .email)
            }
            .opacity(0.1).blur(radius: 6).offset(y: 46).padding(.top, 24)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }
}

/// Profile's sign-in card, pressed: the sheet drops and the main sign-in view returns.
private struct ProfileEntry: View {
    var body: some View {
        TrainingProfileView(personalBest: 11, appearance: .constant("dark"))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 24).strokeBorder(Look.lime, lineWidth: 2)
                    .frame(height: 80).padding(.horizontal, 22).padding(.top, 298)
                    .shadow(color: Look.lime.opacity(0.5), radius: 12)
            }
    }
}

/// Home after signing in: the ball lands in the profile button, which now carries the person.
private struct HomeLanding: View {
    var body: some View {
        HomeView(personalBest: 11, onJuggling: {}, onPowerShot: {}, onImport: {}, onProfile: {}, onSetupGuide: {})
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().strokeBorder(Look.lime.opacity(0.25), lineWidth: 1.5).frame(width: 84, height: 84)
                    Circle().strokeBorder(Look.lime.opacity(0.55), lineWidth: 1.5).frame(width: 64, height: 64)
                    Circle().fill(Look.lime).frame(width: 48, height: 48)
                    Text("J").font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(Look.buttonInk)
                }
                .frame(width: 48, height: 48)
                .padding(.trailing, 20).padding(.top, 10)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Look.lime)
                    Text("Signed in as Jules").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18).frame(height: 48)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 12)
            }
    }
}
#endif
