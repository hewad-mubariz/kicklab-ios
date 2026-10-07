import SwiftUI

struct EffectPickerView: View {
    @Binding var selection: BallStyle
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BallStyle

    init(selection: Binding<BallStyle>) {
        _selection = selection
        _draft = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        ZStack {
            SessionBackdrop()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().strokeBorder(SessionStyle.rim))
                        }.accessibilityLabel("Close effect picker")
                            .accessibilityIdentifier("effect-picker-close")
                        Spacer()
                        Text("KICKLAB").font(Theme.brandWordmark(27)).foregroundStyle(SessionStyle.mint)
                        Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }
                    VStack(spacing: 6) {
                        Text("Choose an Effect").font(.system(size: 29, weight: .bold))
                        Text("Make every touch your own.").font(.system(size: 15)).foregroundStyle(SessionStyle.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                        ForEach(BallStyle.allCases.filter { $0 != .none }) { style in
                            card(style)
                        }
                    }
                    Button { draft = .none } label: {
                        HStack(spacing: 8) {
                            Image(systemName: draft == .none ? "checkmark.circle.fill" : "circle.slash")
                            Text("No effect · Original footage")
                        }.font(.system(size: 14, weight: .medium)).foregroundStyle(draft == .none ? SessionStyle.mint : SessionStyle.secondary)
                            .frame(maxWidth: .infinity).padding(12)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SessionAction(title: "Apply Effect", symbol: "checkmark") {
                selection = draft; dismiss()
            }
            .accessibilityIdentifier("effect-picker-apply")
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(SessionStyle.background.opacity(0.96))
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private func card(_ style: BallStyle) -> some View {
        let selected = draft == style
        return Button { draft = style } label: {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    EffectCardArtwork(name: style.assetName!, size: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                LinearGradient(stops: [.init(color: .clear, location: 0.48),
                    .init(color: SessionStyle.background.opacity(0.92), location: 0.83)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: style.symbol).foregroundStyle(style.tint).shadow(color: style.tint.opacity(0.7), radius: 6)
                        Text(style.title).font(.system(size: 17, weight: .bold))
                    }
                    Text(style.caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2).frame(height: 28, alignment: .topLeading)
                }.padding(12)
            }
            .aspectRatio(0.67, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? SessionStyle.mint : SessionStyle.rim,
                lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 29, height: 29).background(SessionStyle.mint, in: Circle()).padding(10)
                }
            }
            .shadow(color: selected ? SessionStyle.mint.opacity(0.18) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title + ". " + style.caption)
        .accessibilityIdentifier("effect-picker-\(style.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
