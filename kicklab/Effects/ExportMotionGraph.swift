import SwiftUI

/// The replay's analytics as one panel: the motion graph, rhythm and touch interval. It sits on a black
/// card, or simple, laid out as the readout under the replay. The same panel is placed inside the video
/// in replay and rasterized for each media timestamp.
struct ExportMotionGraphCard: View {
    let style: MotionStyle
    let snapshot: MotionStyleSnapshot
    let sourceAspect: CGFloat
    let background: Bool

    var body: some View {
        Group {
            if background {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(style.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                        Spacer()
                        if let status = style.status(snapshot.graph) {
                            Text(status).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
                        }
                    }
                    readout
                }
                .padding(ExportMotionGraphRenderer.padding(background: true))
                .frame(width: panelWidth, height: panelHeight, alignment: .top)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    MotionGraphHeader(style: style, graph: snapshot.graph)
                    readout
                }
                .padding(.horizontal, ExportMotionGraphRenderer.padding(background: false))
                .frame(width: panelWidth, height: panelHeight, alignment: .top)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, AppLanguage.locale)
    }

    private var panelWidth: CGFloat { ExportMotionGraphRenderer.width(background: background) }
    private var panelHeight: CGFloat { ExportMotionGraphRenderer.height(style: style, background: background) }

    @ViewBuilder private var readout: some View {
        MotionStyleGraph(style: style, snapshot: snapshot, sourceAspect: sourceAspect)
            .frame(height: style.height)
        Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
        HStack(spacing: 12) { CaptureRhythmMetrics(rhythm: snapshot.rhythm) }
    }
}

struct ExportMotionGraphLayer: View {
    let style: MotionStyle
    let snapshot: MotionStyleSnapshot
    let size: CGSize
    let background: Bool

    var body: some View {
        let rect = ExportMotionGraphRenderer.rect(style: style, background: background, in: size)
        ExportMotionGraphCard(style: style, snapshot: snapshot, sourceAspect: size.width / max(1, size.height), background: background)
            .scaleEffect(rect.width / ExportMotionGraphRenderer.width(background: background))
            .position(x: rect.midX, y: rect.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(style.title + ": " + String(localized: "included in saved video", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            .accessibilityValue(style.rawValue)
            .accessibilityIdentifier("capture-motion-graph")
    }
}

nonisolated enum ExportMotionGraphRenderer {
    /// The soft shade the replay draws over its footage: clear from here down to `shadeAlpha` at the bottom.
    static let shadeStart: CGFloat = 0.56
    static let shadeAlpha: CGFloat = 0.8

    /// The simple panel uses a full-width phone's points and gutters, so it takes the share of the frame the readout does.
    static func width(background: Bool) -> CGFloat { background ? 342 : 440 }
    static func padding(background: Bool) -> CGFloat { background ? 14 : 24 }

    /// The graph's own height plus the header, divider and readings around it.
    static func height(style: MotionStyle, background: Bool) -> CGFloat { style.height + (background ? 112 : 114) }

    /// The card floats at the bottom of the video. The simple panel sits where the readout does on
    /// the replay: edge to edge in portrait, ending just above the scrubber.
    static func rect(style: MotionStyle, background: Bool, in size: CGSize) -> CGRect {
        let margin = min(size.width, size.height) * 0.04
        let shown = background ? min(size.width - margin * 2, size.height * 0.78) : min(size.width, size.height * 0.85)
        let height = height(style: style, background: background) * shown / width(background: background)
        return CGRect(x: (size.width - shown) / 2, y: (background ? size.height - margin : size.height * 0.88) - height,
                      width: shown, height: height)
    }

    @MainActor
    static func image(style: MotionStyle, snapshot: MotionStyleSnapshot, size: CGSize, background: Bool) -> CGImage? {
        autoreleasepool {
            let renderer = ImageRenderer(content: ExportMotionGraphCard(style: style, snapshot: snapshot,
                sourceAspect: size.width / max(1, size.height), background: background))
            renderer.scale = rect(style: style, background: background, in: size).width / width(background: background)
            return renderer.cgImage
        }
    }

    /// Under the simple panel only. Goes under the counter, as on the replay, so white stays white.
    static func drawShade(in context: CGContext, size: CGSize) {
        guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceRGB(),
                                        colorComponents: [0, 0, 0, 0, 0, 0, 0, shadeAlpha],
                                        locations: [0, 1], count: 2) else { return }
        let top = size.height * shadeStart
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: top, width: size.width, height: size.height - top))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: size.height), options: [])
        context.restoreGState()
    }

    /// The export context uses top-left coordinates; CGImages need their own vertical flip.
    static func draw(_ image: CGImage, in context: CGContext, style: MotionStyle, size: CGSize, background: Bool) {
        let frame = rect(style: style, background: background, in: size)
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }
}
