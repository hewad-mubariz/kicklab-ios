import SwiftUI
import UIKit

/// Ball material and surrounding GPU emission remain independent layers.
struct BallStyleOverlay: View {
    var style: BallStyle
    var presentation: BallStylePresentation
    var intensity: Double
    var sample: BallStyleSample?
    var trail: [BallStyleSample] = []
    var time: TimeInterval = 0
    var skin: BallSkin = .original
    var sourceSize: CGSize = CGSize(width: 9, height: 16)

    var body: some View {
        ZStack {
            if skin != .original {
                BallMaterialSurface(overlay: self)
            }
            if style != .none {
                MetalEffectSurface { size in
                    guard let sample else { return nil }
                    return .tracked(size: size, sourceSize: sourceSize, style: style,
                        intensity: presentation.resolvedIntensity(intensity), sample: sample, trail: trail, time: time)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct BallMaterialSurface: UIViewRepresentable {
    var overlay: BallStyleOverlay
    func makeUIView(context: Context) -> MaterialView {
        let view = MaterialView()
        view.isOpaque = false; view.backgroundColor = .clear
        view.isUserInteractionEnabled = false; view.contentMode = .redraw
        return view
    }
    func updateUIView(_ view: MaterialView, context: Context) { view.overlay = overlay; view.setNeedsDisplay() }
    final class MaterialView: UIView {
        var overlay: BallStyleOverlay?
        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext(), let overlay else { return }
            BallMaterialRenderer.draw(in: ctx, size: bounds.size, sourceSize: overlay.sourceSize,
                skin: overlay.skin,
                sample: overlay.sample, time: overlay.time)
        }
    }
}
