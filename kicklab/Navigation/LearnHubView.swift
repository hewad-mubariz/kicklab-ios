import SwiftUI

/// Placeholder for the juggling lessons. The lessons themselves are planned
/// separately; this only reserves the tab and says what is coming.
struct LearnHubView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Learn")
                        .font(TrainingHomeStyle.display(44, relativeTo: .largeTitle))
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(TrainingHomeStyle.buttonInk)
                            .frame(width: 60, height: 60)
                            .background(TrainingHomeStyle.lime, in: .circle)
                        Text("Juggling lessons")
                            .font(TrainingHomeStyle.display(32, relativeTo: .title))
                        Text("Step by step, from your first touches to longer streaks.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Coming soon")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(TrainingHomeStyle.buttonInk)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(TrainingHomeStyle.lime, in: .capsule)
                            .padding(.top, 4)
                    }
                    .foregroundStyle(.white)
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TrainingHomeStyle.cardBlack, in: .rect(cornerRadius: 24, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("learn-coming-soon")
                }
                .frame(maxWidth: 480).padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.homeBackground(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("learn-screen")
        }
    }
}
