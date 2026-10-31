import SwiftUI

extension TimerOverlayAppearance {
    /// The moment each style reads best as a still: the pulse lit, the ring part-full, the cards at rest.
    nonisolated static func previewTime(_ style: TimerStyle) -> Double {
        switch style {
        case .pill: 12.02
        case .clean: 12.5
        case .broadcast, .stopwatch: 34.5
        case .digital: 12.2
        case .flip: 12.6
        case .neon: 12.5
        }
    }
}

/// Every timer look at a glance, three to a row. The chosen one runs live in its tile, so the
/// pulse, hand, blink or flip is seen before it is on the clip. Placement stays with the drag,
/// pinch and twist on the video.
struct TimerStyleGrid: View {
    @Binding var item: TimerOverlayItem
    var showsProBadges = false
    var onUnlock: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kicks: [TimerStyle: Int] = [:]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 10) {
            ForEach(TimerStyle.allCases) { style in tile(style) }
        }
        .opacity(item.enabled ? 1 : 0.55)
        .sensoryFeedback(.selection, trigger: item.style)
    }

    private func tile(_ style: TimerStyle) -> some View {
        let selected = item.style == style
        return Button {
            guard !showsProBadges || !style.requiresPro else { onUnlock(); return }
            kicks[style, default: 0] += 1
            withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) {
                item.style = style
                item.enabled = true
            }
        } label: {
            VStack(spacing: 5) {
                TimerStyleThumbnail(style: style, live: selected && item.enabled && !reduceMotion)
                    .padding(.horizontal, 6).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(2.2, contentMode: .fit)
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
                    .overlay(alignment: .topLeading) {
                        if showsProBadges && style.requiresPro { ProBadge().padding(4) }
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
        .accessibilityLabel("\(style.title) timer style")
        .accessibilityIdentifier("timer-style-\(style.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Drawn by the same renderer as the exported video. Still tiles are cached; a live tile counts
/// up from its preview moment.
struct TimerStyleThumbnail: View {
    let style: TimerStyle
    var live = false
    @State private var start = Date.now
    private static var cache: [TimerStyle: CGImage] = [:]

    var body: some View {
        Group {
            if live {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    if let image = TimerOverlayAppearance.image(style: style,
                        time: TimerOverlayAppearance.previewTime(style) + elapsed, scale: 1.5) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    }
                }
                .onAppear { start = .now }
            } else if let image = Self.image(for: style) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }

    static func image(for style: TimerStyle) -> CGImage? {
        if let cached = cache[style] { return cached }
        let image = TimerOverlayAppearance.image(style: style, time: TimerOverlayAppearance.previewTime(style), scale: 1.5)
        cache[style] = image
        return image
    }
}
