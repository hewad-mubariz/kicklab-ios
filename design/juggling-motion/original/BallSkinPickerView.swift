import SwiftUI

/// Ball replacement is independent of the trail/effect and commits only on Apply.
struct BallSkinPickerView: View {
    @Binding var selection: BallSkin
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BallSkin

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
                    Button { draft = .original } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.slash").font(.title3)
                            Text("Original ball").font(.subheadline.weight(.medium))
                            Spacer()
                            if draft == .original {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(SessionStyle.mint)
                            }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ball-picker-original")
                    .accessibilityAddTraits(draft == .original ? .isSelected : [])

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(skins) { skin in card(skin) }
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
    }

    private func card(_ skin: BallSkin) -> some View {
        let selected = draft == skin
        return Button { draft = skin } label: {
            VStack(spacing: 9) {
                BallSkinPreview(skin: skin).frame(width: 66, height: 66)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
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
                }
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
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
