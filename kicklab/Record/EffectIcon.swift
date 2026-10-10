import SwiftUI

/// Effect icons render once per effect and ball, off the main actor, on one shared engine.
actor EffectIconStore {
    static let shared = EffectIconStore()
    private var engine: MetalEffectEngine?
    private var images: [String: CGImage] = [:]

    func icon(style: BallStyle, ball: BallSkin) -> CGImage? {
        // The original ball has no material of its own; show the classic print instead.
        let skin = ball == .original ? BallSkin.classic : ball
        let key = "\(style.rawValue):\(skin.rawValue)"
        if let image = images[key] { return image }
        if engine == nil { engine = try? MetalEffectEngine() }
        guard let engine,
              let image = try? EffectIconRenderer.image(shaderStyle: style.shaderID, height: 192,
                  ball: BallSkinSphereRenderer.image(skin: skin, time: 1.4), engine: engine) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[key] = image
        return image
    }
}

/// A football with the effect streaming behind it, drawn by the shipping effect shaders.
struct EffectIcon: View {
    let style: BallStyle
    var ball: BallSkin = .classic
    @State private var image: CGImage?
    @State private var shownKey = ""

    var body: some View {
        let key = "\(style.rawValue):\(ball.rawValue)"
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .id(shownKey)
                    .transition(.opacity)
            }
        }
        .aspectRatio(EffectIconRenderer.aspect, contentMode: .fit)
        .task(id: key) {
            let rendered = await EffectIconStore.shared.icon(style: style, ball: ball)
            guard !Task.isCancelled else { return }
            // Changing the ball crossfades every icon to the new print.
            withAnimation(SessionMotion.fade) { image = rendered; shownKey = key }
        }
        .accessibilityHidden(true)
    }
}
