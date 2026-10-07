import SwiftUI

struct ProcessingOverlay: View {
    var progress: Double
    var stepIndex: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let steps = ["Video saved", "Tracking ball movement", "Calculating stats", "Almost ready…"]

    var body: some View {
        ZStack {
            SessionStyle.background.opacity(0.96)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
            VStack(spacing: 0) {
                Spacer(minLength: 30)
                processingOrb
                Text("Processing Your Session")
                    .font(.system(size: 23, weight: .bold))
                    .padding(.top, 28)
                Text("Saving video and analyzing\nyour juggling…")
                    .font(.system(size: 14)).multilineTextAlignment(.center)
                    .foregroundStyle(SessionStyle.secondary)
                    .lineSpacing(4).padding(.top, 10)
                HStack(spacing: 12) {
                    ProgressView(value: min(1, max(0, progress)))
                        .tint(SessionStyle.mint)
                        .shadow(color: SessionStyle.mint.opacity(0.4), radius: 7)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .padding(.top, 34)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 13) {
                            stepIcon(for: index)
                            Text(title).font(.system(size: 14))
                                .foregroundStyle(index <= stepIndex ? .white : SessionStyle.secondary.opacity(0.6))
                            Spacer()
                        }
                    }
                }
                .padding(.top, 30)
                Spacer(minLength: 35)
                Text("Small touches.\nBig Progress.")
                    .font(.custom("Noteworthy-Bold", size: 24))
                    .multilineTextAlignment(.center)
                    .rotationEffect(.degrees(-7))
                    .padding(.bottom, 36)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 360)
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing your session, \(Int(progress * 100)) percent")
    }

    private var processingOrb: some View {
        ZStack {
            Circle().fill(SessionStyle.mint.opacity(0.14)).blur(radius: 25)
            Circle().stroke(SessionStyle.mint.opacity(0.25), lineWidth: 1).padding(3)
            Circle().trim(from: 0.08, to: 0.83)
                .stroke(AngularGradient(colors: [SessionStyle.mint.opacity(0.25), SessionStyle.mint, .white], center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 30 : progress * 240))
                .padding(13)
                .shadow(color: SessionStyle.mint.opacity(0.5), radius: 9)
            Image("effect-card-none")
                .resizable().scaledToFill()
                .frame(width: 108, height: 108).clipShape(Circle())
                .overlay(Circle().strokeBorder(SessionStyle.mint.opacity(0.5), lineWidth: 1))
            Circle().trim(from: 0.1, to: 0.35).stroke(SessionStyle.mint, lineWidth: 1).padding(23)
                .rotationEffect(.degrees(-50))
        }
        .frame(width: 170, height: 170)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func stepIcon(for index: Int) -> some View {
        if index < stepIndex {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 25)).foregroundStyle(SessionStyle.mint)
        } else if index == stepIndex {
            ZStack {
                Circle().stroke(SessionStyle.mint, lineWidth: 2)
                Circle().fill(SessionStyle.mint.opacity(0.16)).padding(5)
            }.frame(width: 25, height: 25)
        } else {
            Circle().fill(Color.white.opacity(0.18)).frame(width: 25, height: 25)
        }
    }
}
