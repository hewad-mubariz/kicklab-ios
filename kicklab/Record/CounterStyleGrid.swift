import SwiftUI

/// Every counter style at a glance, four to a row. A pick applies at once (and shows the
/// counter if it was hidden); placement stays with the drag, pinch and twist on the video.
struct CounterStyleGrid: View {
    @Binding var item: ExportOverlayItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kicks: [ExportBadgeStyle: Int] = [:]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 10) {
            ForEach(ExportBadgeStyle.allCases) { style in tile(style) }
        }
        .opacity(item.enabled ? 1 : 0.55)
        .sensoryFeedback(.selection, trigger: item.style)
    }

    private func tile(_ style: ExportBadgeStyle) -> some View {
        let selected = item.style == style
        return Button {
            kicks[style, default: 0] += 1
            withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) {
                item.style = style
                item.enabled = true
            }
        } label: {
            VStack(spacing: 5) {
                CounterStyleThumbnail(style: style)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .background(selected ? SessionStyle.mint.opacity(0.1) : .white.opacity(0.04), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(.black, SessionStyle.mint).padding(4)
                                .transition(.sessionPop(scale: 0.2))
                        }
                    }
                    .sessionKick(kicks[style, default: 0], amount: 0.08)
                Text(style.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .accessibilityLabel("\(style.title) counter style")
        .accessibilityIdentifier("counter-style-\(style.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Drawn once per style by the same renderer as the exported video, at its best moment.
struct CounterStyleThumbnail: View {
    let style: ExportBadgeStyle
    private static var cache: [ExportBadgeStyle: CGImage] = [:]

    var body: some View {
        if let image = Self.image(for: style) {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
        }
    }

    static func image(for style: ExportBadgeStyle) -> CGImage? {
        if let cached = cache[style] { return cached }
        let age = CounterArt.previewAge(style)
        let image = ExportOverlayRenderer.image(style: style, time: 24 + age,
                                                counter: .init(count: 24, isTotal: false, age: age), scale: 1)
        cache[style] = image
        return image
    }
}
