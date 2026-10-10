import SwiftUI

/// The same card is placed inside the video in replay and rasterized for each media timestamp.
struct ExportMotionGraphCard: View {
    let style: MotionStyle
    let snapshot: MotionStyleSnapshot
    let sourceAspect: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(style.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Text(snapshot.graph.status).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
            }
            MotionStyleGraph(style: style, snapshot: snapshot, sourceAspect: sourceAspect)
                .frame(height: style.height)
        }
        .padding(14).frame(width: ExportMotionGraphRenderer.cardWidth)
        .foregroundStyle(.white)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
    }
}

struct ExportMotionGraphLayer: View {
    let style: MotionStyle
    let snapshot: MotionStyleSnapshot
    let size: CGSize

    var body: some View {
        let rect = ExportMotionGraphRenderer.rect(style: style, in: size)
        ExportMotionGraphCard(style: style, snapshot: snapshot, sourceAspect: size.width / max(1, size.height))
            .scaleEffect(rect.width / ExportMotionGraphRenderer.cardWidth)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(style.title + ": included in saved video")
            .accessibilityValue(style.rawValue)
            .accessibilityIdentifier("capture-motion-graph")
    }
}

nonisolated enum ExportMotionGraphRenderer {
    static let cardWidth: CGFloat = 342

    static func rect(style: MotionStyle, in size: CGSize) -> CGRect {
        let margin = min(size.width, size.height) * 0.04
        let width = min(size.width - margin * 2, size.height * 0.78)
        let height = (style.height + 48) * width / cardWidth
        return CGRect(x: (size.width - width) / 2, y: size.height - margin - height,
                      width: width, height: height)
    }

    @MainActor
    static func image(style: MotionStyle, snapshot: MotionStyleSnapshot, size: CGSize) -> CGImage? {
        autoreleasepool {
            let renderer = ImageRenderer(content: ExportMotionGraphCard(style: style, snapshot: snapshot,
                sourceAspect: size.width / max(1, size.height)))
            renderer.scale = rect(style: style, in: size).width / cardWidth
            return renderer.cgImage
        }
    }

    /// The export context uses top-left coordinates; CGImages need their own vertical flip.
    static func draw(_ image: CGImage, in context: CGContext, style: MotionStyle, size: CGSize) {
        let frame = rect(style: style, in: size)
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }
}
