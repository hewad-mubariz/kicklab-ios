import SwiftUI
import UIKit

/// Native simultaneous recognizers let one/two fingers move, pinch and twist
/// the same sticker. Every delta is applied in the fixed video coordinate space.
struct CounterStickerInteraction: UIViewRepresentable {
    @Binding var placement: ExportOverlayPlacement

    func makeUIView(context: Context) -> CounterStickerGestureView {
        CounterStickerGestureView()
    }

    func updateUIView(_ view: CounterStickerGestureView, context: Context) {
        view.placement = placement
        view.onChange = { placement = $0 }
    }
}

final class CounterStickerGestureView: UIView, UIGestureRecognizerDelegate {
    var placement = ExportOverlayPlacement()
    var onChange: ((ExportOverlayPlacement) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(moveSticker(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(sizeSticker(_:)))
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotateSticker(_:)))
        for gesture in [pan, pinch, rotation] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The gesture surface fills the video but only the sticker catches touches.
        placement.contains(point, in: bounds.size, padding: 22)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === self && otherGestureRecognizer.view === self
    }

    private func update(_ next: ExportOverlayPlacement) {
        placement = next
        onChange?(next)
    }

    @objc private func moveSticker(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        let delta = gesture.translation(in: self)
        update(placement.translated(by: CGSize(width: delta.x, height: delta.y), in: bounds.size))
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func sizeSticker(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        update(placement.transformed(scale: placement.scale * gesture.scale, in: bounds.size))
        gesture.scale = 1
    }

    @objc private func rotateSticker(_ gesture: UIRotationGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        update(placement.transformed(rotation: placement.rotation + gesture.rotation * 180 / .pi, in: bounds.size))
        gesture.rotation = 0
    }
}
