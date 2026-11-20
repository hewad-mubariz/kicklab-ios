import SwiftUI

/// Uses the same bundled material and renderer as replay and export.
struct BallSkinPreview: View {
    let skin: BallSkin
    @State private var image: CGImage?

    init(skin: BallSkin) {
        self.skin = skin
        // The shipped resting ball, so the tile never waits for the GPU.
        _image = State(initialValue: ShippedBallImage.image(for: skin))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: skin) {
            if let shipped = ShippedBallImage.image(for: skin) { image = shipped; return }
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
