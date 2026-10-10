import SwiftUI

/// The selected Soft Halo study, drawn natively so the glow and mark stay crisp.
struct SoftHaloSplashView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let markWidth = min(190, min(geometry.size.width * 0.46, geometry.size.height * 0.30))
            let haloSize = min(520, max(340, geometry.size.width * 1.15))

            ZStack {
                Color("LaunchBackground")

                RadialGradient(
                    stops: [
                        .init(color: lime.opacity(scheme == .dark ? 0.25 : 0.22), location: 0),
                        .init(color: lime.opacity(scheme == .dark ? 0.11 : 0.09), location: 0.40),
                        .init(color: lime.opacity(0), location: 1)
                    ],
                    center: .center, startRadius: 0, endRadius: haloSize / 2
                )
                .frame(width: haloSize, height: haloSize)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.46)

                VStack(spacing: 18) {
                    LiftBrandMark()
                        .frame(width: markWidth, height: markWidth * 582 / 640)
                        .accessibilityHidden(true)
                    Text("Juggle Dude")
                        .font(.system(size: min(34, markWidth * 0.18), weight: .semibold))
                        .tracking(-1.1)
                        .foregroundStyle(scheme == .dark ? Color.white : Color(red: 0.06, green: 0.075, blue: 0.075))
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.48)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Juggle Dude")
        .accessibilityIdentifier("juggledude-splash")
    }

    private var lime: Color { Color(red: 0.80, green: 0.98, blue: 0.345) }
}

/// Keep the destination mounted while the opening fades, without accepting hidden taps.
/// State lives at the root, so navigating or returning from the background never replays it.
struct SoftHaloOpening: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowing = true

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(!isShowing)
                .accessibilityHidden(isShowing)
            if isShowing {
                SoftHaloSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .statusBarHidden(isShowing)
        .task {
            guard isShowing else { return }
            #if DEBUG
            // Freeze only for Xcode/simulator artwork review, never in Release.
            if ProcessInfo.processInfo.arguments.contains("--splash-preview") { return }
            #endif
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                isShowing = false
            }
        }
    }
}

#Preview("Soft Halo · Dark") {
    SoftHaloSplashView().preferredColorScheme(.dark)
}

#Preview("Soft Halo · Light") {
    SoftHaloSplashView().preferredColorScheme(.light)
}
