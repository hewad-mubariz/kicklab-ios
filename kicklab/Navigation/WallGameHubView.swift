import SwiftUI

/// The V2 destination is available before the experimental camera/projector
/// runtime is qualified for the main app. This page never starts that runtime.
struct WallGameHubView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var showsSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wall Game")
                        .font(TrainingHomeStyle.display(44, relativeTo: .largeTitle))
                        .accessibilityAddTraits(.isHeader)
                    Text("Six targets. One wall.")
                        .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                }

                VStack(alignment: .leading, spacing: 22) {
                    Label("Planned for v2", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrainingHomeStyle.lime)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.08), in: .capsule)
                        .accessibilityIdentifier("wall-game-status")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clear the wall")
                            .font(TrainingHomeStyle.display(42, relativeTo: .largeTitle))
                        Text("Hit every target. Beat your time.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(1...6, id: \.self) { number in
                            Text(number.formatted())
                                .font(.title2.weight(.bold).monospacedDigit())
                                .foregroundStyle(TrainingHomeStyle.lime)
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                                .background(.white.opacity(0.04), in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(TrainingHomeStyle.lime.opacity(0.75), lineWidth: 2))
                        }
                    }
                    .accessibilityHidden(true)

                    Text("Game preview").font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white).padding(22)
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.21, blue: 0.12),
                                                      TrainingHomeStyle.cardBlack],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("What you’ll need", systemImage: "video")
                        .font(.headline)
                    Text("A ball, a clear wall, a fixed iPhone and a projector.")
                        .font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    Button { showsSetup = true } label: {
                        HStack {
                            Text("See the setup").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .frame(minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(TrainingHomeStyle.accent(scheme))
                    .accessibilityIdentifier("wall-game-setup")
                }
                .padding(20)
                .background(TrainingHomeStyle.panel(scheme), in: .rect(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(TrainingHomeStyle.line(scheme)))

                Text("Full game coming in v2.")
                    .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            .frame(maxWidth: 480).padding(20).frame(maxWidth: .infinity)
        }
        .background(TrainingHomeStyle.homeBackground(scheme))
        .foregroundStyle(TrainingHomeStyle.ink(scheme))
        .accessibilityIdentifier("wall-game-screen")
        .sheet(isPresented: $showsSetup) { WallGameSetupGuide() }
    }
}

private struct WallGameSetupGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    step("1", symbol: "videoprojector", title: "Project the targets",
                         detail: "Project the six-target board onto your wall.")
                    step("2", symbol: "iphone.gen3", title: "Position your iPhone",
                         detail: "Keep the phone still in landscape with the whole board visible.")
                    step("3", symbol: "viewfinder", title: "Align, then play",
                         detail: "Check the corners and ball position before the round begins.")
                    Text("Full game coming in v2.")
                        .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                }
                .frame(maxWidth: 480).padding(24).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.background(scheme))
            .foregroundStyle(TrainingHomeStyle.ink(scheme))
            .navigationTitle("Wall setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("wall-game-setup-done")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func step(_ number: String, symbol: String, title: LocalizedStringKey,
                      detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(TrainingHomeStyle.accent(scheme))
                Text(number).font(.caption.weight(.bold)).foregroundStyle(TrainingHomeStyle.muted(scheme))
                Text(title).font(.headline)
            }
            Text(detail).font(.body).foregroundStyle(TrainingHomeStyle.muted(scheme))
        }
    }
}
