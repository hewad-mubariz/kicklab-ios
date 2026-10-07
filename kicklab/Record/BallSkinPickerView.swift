import SwiftUI

/// Ball replacement is independent of the trail/effect and commits only on Apply.
struct BallSkinPickerView: View {
    @Binding var selection: BallSkin
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: BallSkin
    @State private var appeared = false

    private let skins: [BallSkin] = [.chrome, .arctic, .matrix, .stealth, .crimson,
                                     .gold, .galaxy, .graffiti, .aurora, .classic]

    init(selection: Binding<BallSkin>) {
        _selection = selection
        _draft = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose your ball’s look.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .sessionEntrance(appeared, offset: 8)
                    Button { choose(.original) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.slash").font(.title3)
                            Text("Original ball").font(.subheadline.weight(.medium))
                            Spacer()
                            if draft == .original {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(SessionStyle.mint)
                                    .transition(.sessionPop(scale: 0.2))
                            }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(SessionPressStyle(scale: 0.97))
                    .accessibilityIdentifier("ball-picker-original")
                    .accessibilityAddTraits(draft == .original ? .isSelected : [])
                    .sessionEntrance(appeared, order: 1, offset: 12)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(Array(skins.enumerated()), id: \.element) { index, skin in
                            card(skin).sessionEntrance(appeared, order: 2 + index, offset: 18, scale: 0.9)
                        }
                    }
                }.padding(20)
            }
            .background(SessionStyle.background)
            .navigationTitle("Ball")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close ball picker", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("ball-picker-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { selection = draft; dismiss() }
                        .buttonStyle(.glassProminent).tint(SessionStyle.mint)
                        .accessibilityIdentifier("ball-picker-apply")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { appeared = true }
        .sensoryFeedback(.selection, trigger: draft)
    }

    private func choose(_ skin: BallSkin) {
        withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { draft = skin }
    }

    private func card(_ skin: BallSkin) -> some View {
        let selected = draft == skin
        return Button { choose(skin) } label: {
            VStack(spacing: 9) {
                // The chosen ball bounces up a size.
                BallSkinPreview(skin: skin).frame(width: 66, height: 66)
                    .scaleEffect(selected && !reduceMotion ? 1.12 : 1)
                    .shadow(color: .black.opacity(selected ? 0.32 : 0.2), radius: selected ? 9 : 6, y: selected ? 7 : 4)
                    .animation(reduceMotion ? nil : .bouncy(duration: 0.38, extraBounce: 0.18), value: selected)
                Text(skin.title).font(.system(size: 12, weight: .medium))
                    .lineLimit(2).frame(height: 30)
            }
            .padding(.horizontal, 8).padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.025)],
                startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.black, SessionStyle.mint).padding(8)
                        .transition(.sessionPop(scale: 0.2))
                }
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(SessionPressStyle(scale: 0.93)).foregroundStyle(.white)
        .accessibilityLabel(skin.title)
        .accessibilityIdentifier("ball-picker-\(skin.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Uses the same bundled material and renderer as replay and export.
struct BallSkinPreview: View {
    let skin: BallSkin
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: skin) {
            let requestedSkin = skin
            let rendered = await Task.detached(priority: .userInitiated) {
                BallSkinSphereRenderer.image(skin: requestedSkin, time: 1.4)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
        .accessibilityHidden(true)
    }
}
