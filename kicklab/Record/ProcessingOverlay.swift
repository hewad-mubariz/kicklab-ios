import SwiftUI

struct ProcessingOverlay: View {
    var progress: Double
    var stepIndex: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let steps = ["Video saved", "Tracking ball movement", "Calculating stats", "Almost ready…"]
    /// Every step done: the ring closes, then the content clears for the editor.
    private var complete: Bool { stepIndex >= steps.count }

    var body: some View {
        ZStack {
            // The ground appears at once (no black gap after Stop); only the content moves.
            SessionStyle.background.opacity(0.96)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
            VStack(spacing: 0) {
                Spacer(minLength: 30)
                processingOrb
                    .sessionEntrance(appeared, offset: 0, scale: 0.6)
                Text("Processing Your Session")
                    .font(.system(size: 23, weight: .bold))
                    .padding(.top, 28)
                    .sessionEntrance(appeared, order: 2)
                Text("Saving video and analyzing\nyour juggling…")
                    .font(.system(size: 14)).multilineTextAlignment(.center)
                    .foregroundStyle(SessionStyle.secondary)
                    .lineSpacing(4).padding(.top, 10)
                    .sessionEntrance(appeared, order: 3)
                HStack(spacing: 12) {
                    ProgressView(value: min(1, max(0, progress)))
                        .tint(SessionStyle.mint)
                        .shadow(color: SessionStyle.mint.opacity(0.4), radius: 7)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                }
                .padding(.top, 34)
                .sessionEntrance(appeared, order: 4)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 13) {
                            ZStack { stepIcon(for: index) }.frame(width: 25, height: 25)
                            Text(title).font(.system(size: 14))
                                .foregroundStyle(index <= stepIndex ? .white : SessionStyle.secondary.opacity(0.6))
                            Spacer()
                        }
                        .sessionEntrance(appeared, order: 5 + index, offset: 10)
                    }
                }
                .padding(.top, 30)
                .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: stepIndex)
                Spacer(minLength: 35)
                Text("Small touches.\nBig Progress.")
                    .font(.custom("Noteworthy-Bold", size: 24))
                    .multilineTextAlignment(.center)
                    .rotationEffect(.degrees(-7))
                    .padding(.bottom, 36)
                    .sessionEntrance(appeared, order: 10, offset: 10)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 360)
            .padding(.horizontal, 32)
            // Exit beat: the finished screen lifts away just before the editor appears.
            .scaleEffect(complete && !reduceMotion ? 1.05 : 1)
            .opacity(complete ? 0 : 1)
            .animation(reduceMotion ? SessionMotion.fade : .easeIn(duration: 0.2).delay(0.2), value: complete)
        }
        .transition(.opacity)
        .onAppear { appeared = true }
        .sensoryFeedback(.success, trigger: complete) { _, done in done }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing your session, \(Int(progress * 100)) percent")
    }

    private var processingOrb: some View {
        ZStack {
            Circle().fill(SessionStyle.mint.opacity(complete ? 0.3 : 0.14)).blur(radius: 25)
            Circle().stroke(SessionStyle.mint.opacity(0.25), lineWidth: 1).padding(3)
            orbit
            Image("effect-card-none")
                .resizable().scaledToFill()
                .frame(width: 108, height: 108).clipShape(Circle())
                .overlay(Circle().strokeBorder(SessionStyle.mint.opacity(0.5), lineWidth: 1))
            Circle().trim(from: 0.1, to: 0.35).stroke(SessionStyle.mint, lineWidth: 1).padding(23)
                .rotationEffect(.degrees(-50))
        }
        .frame(width: 170, height: 170)
        .sessionKick(complete ? 1 : 0, amount: 0.06)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: complete)
        .accessibilityHidden(true)
    }

    /// Progress turns the arc; while work is running it also drifts so the wait reads as alive.
    private var orbit: some View {
        TimelineView(.animation(paused: reduceMotion || complete)) { clock in
            let drift = reduceMotion || complete ? 0 : (clock.date.timeIntervalSinceReferenceDate * 90).truncatingRemainder(dividingBy: 360)
            Circle().trim(from: complete ? 0 : 0.08, to: complete ? 1 : 0.83)
                .stroke(AngularGradient(colors: [SessionStyle.mint.opacity(0.25), SessionStyle.mint, .white], center: .center),
                        style: StrokeStyle(lineWidth: complete ? 3 : 2, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 30 : progress * 240 + drift))
                .padding(13)
                .shadow(color: SessionStyle.mint.opacity(complete ? 0.9 : 0.5), radius: complete ? 14 : 9)
        }
    }

    @ViewBuilder private func stepIcon(for index: Int) -> some View {
        if index < stepIndex {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 25)).foregroundStyle(SessionStyle.mint)
                .transition(.sessionPop(scale: 0.3))
        } else if index == stepIndex {
            ZStack {
                Circle().stroke(SessionStyle.mint, lineWidth: 2)
                Circle().fill(SessionStyle.mint.opacity(0.16)).padding(5)
            }
            .transition(.sessionPop(scale: 1.4))
        } else {
            Circle().fill(Color.white.opacity(0.18))
                .transition(.opacity)
        }
    }
}
