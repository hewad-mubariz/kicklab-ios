import SwiftUI

/// Motion for capture → processing → replay → export. Short springs with a little
/// overshoot so controls feel physical, then settle. Under Reduce Motion every
/// movement collapses to a plain fade; nothing idles once it has arrived.
enum SessionMotion {
    /// Control morphs: shutter, symbol swaps, selection.
    static let snap = Animation.snappy(duration: 0.28, extraBounce: 0.12)
    /// Panels, cards and stickers arriving.
    static let pop = Animation.spring(response: 0.36, dampingFraction: 0.7)
    /// Large surfaces settling: video, toolbox.
    static let settle = Animation.spring(response: 0.44, dampingFraction: 0.86)
    static let fade = Animation.easeOut(duration: 0.18)
    /// The Customize tray resizing between pages; the video above it rides the same curve.
    static let tray = Animation.spring(response: 0.4, dampingFraction: 0.86)
    /// Delay between staggered siblings.
    static let stagger = 0.045

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

// MARK: - Transitions

/// Shared by every session transition: hidden state moves, scales and softens; the
/// shown state is the view untouched. Reduce Motion keeps only the opacity.
private struct SessionTransitionModifier: ViewModifier {
    let hidden: Bool
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var anchor: UnitPoint = .center
    var blur: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moving = hidden && !reduceMotion
        content
            .scaleEffect(moving ? scale : 1, anchor: anchor)
            .offset(moving ? offset : .zero)
            .blur(radius: moving ? blur : 0)
            .opacity(hidden ? 0 : 1)
    }
}

extension AnyTransition {
    private static func session(offset: CGSize = .zero, scale: CGFloat = 1,
                                anchor: UnitPoint = .center, blur: CGFloat = 0) -> AnyTransition {
        .modifier(active: SessionTransitionModifier(hidden: true, offset: offset, scale: scale, anchor: anchor, blur: blur),
                  identity: SessionTransitionModifier(hidden: false))
    }

    /// Springs out of its anchor, small and soft, then settles.
    static func sessionPop(from anchor: UnitPoint = .center, scale: CGFloat = 0.6) -> AnyTransition {
        session(scale: scale, anchor: anchor, blur: 4)
    }

    /// Rises a few points into place.
    static var sessionRise: AnyTransition { session(offset: CGSize(width: 0, height: 14), blur: 2) }

    /// Drops in from above.
    static var sessionDrop: AnyTransition { session(offset: CGSize(width: 0, height: -12), blur: 2) }

    /// Tucks sideways toward an edge, shrinking as it goes.
    static func sessionTuck(_ edge: HorizontalEdge) -> AnyTransition {
        session(offset: CGSize(width: edge == .leading ? -26 : 26, height: 0), scale: 0.5, blur: 3)
    }
}

// MARK: - Entrances

/// Arrives once, a beat after the siblings before it.
private struct SessionEntrance: ViewModifier {
    let shown: Bool
    let order: Int
    let offset: CGFloat
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : scale)
            .offset(y: shown || reduceMotion ? 0 : offset)
            .animation(reduceMotion ? SessionMotion.fade
                       : SessionMotion.pop.delay(Double(order) * SessionMotion.stagger), value: shown)
    }
}

extension View {
    /// Staggered arrival. A negative offset drops in from above.
    func sessionEntrance(_ shown: Bool, order: Int = 0, offset: CGFloat = 18, scale: CGFloat = 1) -> some View {
        modifier(SessionEntrance(shown: shown, order: order, offset: offset, scale: scale))
    }
}

// MARK: - Press

/// Dips quickly on touch and springs back with a little overshoot on release.
struct SessionPressStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : configuration.isPressed
                       ? .spring(response: 0.16, dampingFraction: 0.9)
                       : .spring(response: 0.32, dampingFraction: 0.52),
                       value: configuration.isPressed)
    }
}

// MARK: - One-shot accents

/// A quick scale kick each time `trigger` changes; at rest it is the identity.
private struct SessionKick: ViewModifier {
    let trigger: Int
    let amount: CGFloat
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: reduceMotion ? 0 : trigger) { view, scale in
            view.scaleEffect(scale, anchor: anchor)
        } keyframes: { _ in
            SpringKeyframe(1 + amount, duration: 0.08, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy(duration: 0.34, extraBounce: 0.12))
        }
    }
}

extension View {
    func sessionKick(_ trigger: Int, amount: CGFloat = 0.1, anchor: UnitPoint = .center) -> some View {
        modifier(SessionKick(trigger: trigger, amount: amount, anchor: anchor))
    }
}

// MARK: - Navigation

extension SessionMotion {
    static let exportZoomID = "session-export"
}

extension View {
    /// Marks the view Save & Share zooms out of, when the flow provides a namespace.
    @ViewBuilder func exportZoomSource(_ namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: SessionMotion.exportZoomID, in: namespace)
        } else {
            self
        }
    }
}
