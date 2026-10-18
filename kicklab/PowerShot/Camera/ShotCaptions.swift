import CoreGraphics
import CoreText
import SwiftUI

/// Draws camera captions into a saved frame. The preview shows the same values with SwiftUI.
nonisolated enum ShotCaptionRenderer {
    /// `context` uses Core Graphics' bottom-left origin; captions are top-left positioned.
    static func draw(_ captions: [ShotCaption], in context: CGContext, height: CGFloat) {
        for caption in captions where caption.alpha > 0.01 && !caption.text.isEmpty {
            let font = CTFontCreateUIFontForLanguage(caption.bold ? .emphasizedSystem : .system, caption.size, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, caption.size, nil)
            let color = CGColor(srgbRed: CGFloat(caption.color.x), green: CGFloat(caption.color.y), blue: CGFloat(caption.color.z),
                                alpha: CGFloat(caption.alpha))
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
                                               kCTKernAttributeName: caption.size * 0.04]
            guard let text = CFAttributedStringCreate(nil, caption.text as CFString, attributes as CFDictionary) else { continue }
            let line = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x: CGFloat = switch caption.align {
            case .leading: caption.position.x
            case .center: caption.position.x - width / 2
            case .trailing: caption.position.x - width
            }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 7,
                              color: CGColor(gray: 0, alpha: 0.55 * CGFloat(caption.alpha)))
            context.textPosition = CGPoint(x: x, y: height - (caption.position.y + caption.size * 0.78))
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}

/// The preview's caption layer: positions are output pixels, scaled to the on-screen frame.
struct ShotCaptionOverlay: View {
    let captions: [ShotCaption]
    /// Size of the picture the captions were computed for.
    let canvas: CGSize

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(1, canvas.width)
            ZStack(alignment: .topLeading) {
                ForEach(Array(captions.enumerated()), id: \.offset) { _, caption in
                    label(caption, scale: scale)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func label(_ caption: ShotCaption, scale: CGFloat) -> some View {
        let size = caption.size * scale
        let anchor: Alignment = caption.align == .leading ? .leading : caption.align == .center ? .center : .trailing
        let color = Color(red: Double(caption.color.x), green: Double(caption.color.y), blue: Double(caption.color.z))
        // A zero-width frame anchors the text's leading, centre or trailing edge at the point.
        return Text(caption.text)
            .font(.system(size: size, weight: caption.bold ? .bold : .regular))
            .kerning(size * 0.04)
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.55), radius: 3.5, y: 1.5)
            .fixedSize()
            .frame(width: 0, alignment: anchor)
            .offset(x: caption.position.x * scale, y: caption.position.y * scale)
            .opacity(caption.alpha)
    }
}
