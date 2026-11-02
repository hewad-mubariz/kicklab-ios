import SwiftUI

/// Effect icons render once per effect and ball, off the main actor, on one shared engine.
actor EffectIconStore {
    static let shared = EffectIconStore()
    private var engine: MetalEffectEngine?
    private var images: [String: CGImage] = [:]
    private var solving: [BallStyle: Task<Void, Never>] = [:]

    func icon(style: BallStyle, ball: BallSkin) async -> CGImage? {
        // The original ball has no material of its own; show the classic print instead.
        let skin = ball == .original ? BallSkin.classic : ball
        let key = "\(style.rawValue):\(skin.rawValue)"
        if let image = images[key] { return image }
        await solve(style)
        if let image = images[key] { return image }
        if engine == nil { engine = try? MetalEffectEngine() }
        guard let engine,
              let image = try? EffectIconRenderer.image(shaderStyle: style.shaderID, height: 192,
                  ball: BallSkinSphereRenderer.image(skin: skin, time: 1.4), engine: engine) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[key] = image
        return image
    }

    /// Liquid and Water solve their fluid for seconds before the first frame (16 s for Water in the
    /// Simulator). The solve runs off this actor, once, so icons already drawn keep coming back at
    /// once meanwhile instead of queueing behind it.
    private func solve(_ style: BallStyle) async {
        guard style == .liquid || style == .water else { return }
        // Both pour with Water's solved crown.
        let task = solving[.water] ?? Task.detached(priority: .userInitiated) {
            WaterCrown.prepareAll()
        }
        solving[.water] = task
        await task.value
    }

    /// Renders every effect's icon for `ball` ahead of time, so the Effects page opens complete. One
    /// actor call per icon, so a tile asking for its own never waits behind the whole set; the lab
    /// effects, which solve their fluid first, come last.
    nonisolated func prepare(ball: BallSkin) async {
        for style in BallStyle.selectableCases.sorted(by: { !$0.isLabEffect && $1.isLabEffect }) {
            guard !Task.isCancelled else { return }
            _ = await icon(style: style, ball: ball)
        }
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
            // Holds the tile's full size while the icon renders, so the grid and the tray around it
            // never resize as icons arrive one by one.
            Color.clear
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
