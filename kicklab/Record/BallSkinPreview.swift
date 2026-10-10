import SwiftUI

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
