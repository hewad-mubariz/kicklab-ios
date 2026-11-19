import SwiftUI
import simd

/// Picking a ball plays like a keepy-up. It pops straight up off its own spot, a little toward
/// you (never smaller than at rest), tumbling on its real printed panels while its shadow
/// shrinks below, and drops back in a small frost burst (ripples, a flash and ice shards) as
/// the ice pad under it lights up. It never leaves its spot, so it suits a full grid.
/// Reduce Motion keeps the lit pad, without the hop.
struct BallPickSlot: View {
    let skin: BallSkin
    let selected: Bool
    /// Bumped on every pick of this ball; each change plays the moment once.
    let picks: Int
    var size: CGFloat = 62
    /// The lean of the spin: 1 tips right, -1 left, 0 spins straight; edge columns lean inward.
    var direction: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: CGImage?
    /// The ball's resting pose; every pick spins it on from here.
    @State private var restOrientation = simd_quatf(angle: 1.89, axis: SIMD3(0, 1, 0))
        * simd_quatf(angle: 0.59, axis: SIMD3(1, 0, 0))
    @State private var landings = 0
    /// Picks made before this slot appeared; returning to the page must not replay them.
    @State private var picksAtAppear: Int

    init(skin: BallSkin, selected: Bool, picks: Int, size: CGFloat = 62, direction: CGFloat = 1) {
        self.skin = skin; self.selected = selected; self.picks = picks; self.size = size
        self.direction = direction
        _picksAtAppear = State(initialValue: picks)
    }

    private var isNewPick: Bool { picks > picksAtAppear && !reduceMotion }

    /// Seconds from the tap to the ball dropping back onto its spot.
    private static let landing = 0.42
    /// Where the ball meets the floor, below the slot centre.
    private var ground: CGFloat { size * 0.44 }

    var body: some View {
        ZStack {
            icePad
            KeyframeAnimator(initialValue: Flight(), trigger: reduceMotion ? 0 : picks) { flight in
                let spot = loop(flight.progress)
                ZStack {
                    shadow(spot)
                    groundRipples(flight.impact)
                    flightGlow(spot)
                    ball
                        .frame(width: size, height: size)
                        .scaleEffect((1 + 0.5 * spot.depth) * flight.pulse)
                        .rotationEffect(.degrees(-10 * Double(direction) * sin(flight.progress * .pi)
                                                 + (skin == .original ? 720 * flight.progress : 0)))
                        .offset(x: spot.point.x, y: spot.point.y + flight.hop)
                    frostBurst(flight.impact)
                }
                .frame(width: size, height: size)
            } keyframes: { _ in
                KeyframeTrack(\.progress) {
                    LinearKeyframe(0, duration: 0.03)
                    // Leaves fast off the kick, carries over the top, lands with some speed.
                    CubicKeyframe(1, duration: Self.landing - 0.03, startVelocity: 2.8, endVelocity: 1.3)
                }
                KeyframeTrack(\.hop) {
                    LinearKeyframe(0, duration: Self.landing)
                    CubicKeyframe(-4, duration: 0.06)
                    SpringKeyframe(0, duration: 0.2, spring: .snappy)
                }
                KeyframeTrack(\.pulse) {
                    LinearKeyframe(1, duration: Self.landing)
                    CubicKeyframe(1.07, duration: 0.05)
                    SpringKeyframe(1, duration: 0.2, spring: .snappy)
                }
                KeyframeTrack(\.impact) {
                    LinearKeyframe(0, duration: Self.landing)
                    LinearKeyframe(1, duration: 0.36)
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: skin) {
            guard frame == nil else { return }
            let first = await render(restOrientation, moving: false)
            withAnimation(.easeOut(duration: 0.25)) { frame = first }
        }
        .task(id: picks) { await spin() }
        .task(id: picks) { await touchDown() }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: landings)
    }

    /// The pick, in slot points: a kick straight up off the pad and back down onto it, so the
    /// ball never leaves its own spot in a full grid. Depth is how close it has come toward the
    /// viewer, highest at the top of the hop.
    private func loop(_ progress: Double) -> (point: CGPoint, depth: Double) {
        let lift = sin(progress * .pi)
        return (CGPoint(x: 0, y: -size * 0.42 * lift), 0.3 * lift)
    }

    @ViewBuilder private var ball: some View {
        if skin == .original {
            Image(systemName: "soccerball").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.75))
        } else if let frame {
            Image(decorative: frame, scale: 1).resizable().scaledToFit().padding(size * 0.035)
                .transition(.opacity)
        } else {
            // A faint ball holds the spot while the first frame draws, so the grid never shows a hole.
            Circle().fill(.white.opacity(0.05))
                .overlay { Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.75) }
                .padding(size * 0.06)
        }
    }

    // MARK: - Resting

    /// The chosen ball stands on a lit ice pedestal with a cold glow behind it.
    /// It lights as the ball lands, so the frost burst becomes the pad.
    private var icePad: some View {
        let lit = selected
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Frost.glacier.opacity(0.22), Frost.deep.opacity(0.06), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.7))
                .frame(width: size * 1.45, height: size * 1.45)
                .opacity(lit ? 1 : 0)
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Frost.ice.opacity(0.5), Frost.glacier.opacity(0.2), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.55))
                    .frame(width: size * 1.38, height: size * 0.36)
                    .blur(radius: 3)
                Ellipse()
                    .strokeBorder(AngularGradient(colors: [.white.opacity(0.75), Frost.ice.opacity(0.7), Frost.glacier.opacity(0.1),
                                                           Frost.ice.opacity(0.7), .white.opacity(0.75)], center: .center), lineWidth: 1.1)
                    .frame(width: size * 1.2, height: size * 0.3)
                    .shadow(color: Frost.ice.opacity(0.5), radius: 3)
            }
            .offset(y: ground)
            .scaleEffect(lit || reduceMotion ? 1 : 0.55, anchor: UnitPoint(x: 0.5, y: 0.5 + ground / size))
            .opacity(lit ? 1 : 0)
        }
        .blendMode(.plusLighter)
        .animation(lit && !reduceMotion ? .spring(response: 0.26, dampingFraction: 0.66).delay(Self.landing - 0.02)
                   : .easeOut(duration: 0.18), value: lit)
        .allowsHitTesting(false)
    }

    /// Every ball sits on its own soft shadow; in flight it shrinks and softens with height.
    private func shadow(_ spot: (point: CGPoint, depth: Double)) -> some View {
        Ellipse().fill(.black.opacity(0.4 * (1 - spot.depth)))
            .frame(width: size * 0.66 * (1 - 0.45 * spot.depth), height: size * 0.14)
            .blur(radius: 2 + 4 * spot.depth)
            .offset(x: spot.point.x * 0.5, y: ground)
            .allowsHitTesting(false)
    }

    // MARK: - Flight

    /// The ball runs cold while it flies: an ice glow that grows as it comes toward you.
    private func flightGlow(_ spot: (point: CGPoint, depth: Double)) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Frost.ice.opacity(0.6), Frost.glacier.opacity(0.28), .clear],
                                 center: .center, startRadius: 0, endRadius: size * 0.75))
            .frame(width: size * 1.2, height: size * 1.2)
            .scaleEffect(1 + 0.5 * spot.depth)
            .opacity(min(1, spot.depth * 1.6))
            .offset(x: spot.point.x, y: spot.point.y)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    // MARK: - Landing

    /// A cold flash behind the ball and two frost ripples spreading flat across the
    /// floor, in perspective, from the touchdown.
    private func groundRipples(_ impact: Double) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white, Frost.ice.opacity(0.8), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.5))
                .frame(width: size, height: size)
                .scaleEffect(0.5 + 1.2 * min(1, impact * 2.2))
                .opacity(impact > 0 ? max(0, 1 - impact * 2.2) : 0)
                .offset(y: -size * 0.12)
            ForEach(0..<2, id: \.self) { index in
                let wave = min(1, max(0, impact * 1.4 - Double(index) * 0.22))
                let width = size * (0.95 + 0.85 * wave)
                Ellipse()
                    .stroke(LinearGradient(colors: [.white, Frost.ice, Frost.glacier],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 2.4 * (1 - wave) + 0.6)
                    .frame(width: width, height: width * 0.26)
                    .shadow(color: Frost.ice, radius: 5)
                    .opacity(wave > 0 ? (1 - wave) * (index == 0 ? 1 : 0.7) : 0)
            }
        }
        .offset(y: ground)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    /// Ice shards kicked up off the pad's rim, thrown out and pulled back down.
    private func frostBurst(_ impact: Double) -> some View {
        ZStack {
            ForEach(0..<10, id: \.self) { index in
                // Two sprays, left and right off the rim, so none crosses the ball's face.
                let side = Double(index % 5) / 4
                let angle = index < 5 ? -Double.pi * (0.62 + 0.3 * side) : -Double.pi * (0.08 + 0.3 * side)
                // Short throws, so the shards stay on this ball's spot and off its neighbours.
                let speed = size * (0.7 + 0.35 * Double((index * 7) % 5) / 4)
                let t = impact
                // Launched from the rim of the pad, clear of the ball itself.
                let x = cos(angle) * (size * 0.36 + speed * t)
                let y = sin(angle) * speed * t + 0.5 * size * 1.8 * t * t
                Rectangle()
                    .fill(LinearGradient(colors: [.white, Frost.ice], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.2, height: 6 + 2 * CGFloat(index % 3))
                    .rotationEffect(.radians(angle + .pi / 2 + t * (index.isMultiple(of: 2) ? 7 : -7)))
                    .shadow(color: Frost.ice, radius: 2)
                    .offset(x: x, y: ground + y)
                    .opacity(t > 0 ? max(0, 1 - pow(t, 1.4)) : 0)
            }
        }
        .allowsHitTesting(false)
    }

    /// Backspin like a ball lifted off the laces: it rolls end over end, its front panels
    /// turning up toward you, 2½ turns, fastest off the kick and easing into the landing.
    /// The spin axis leans with the swing, so each side gets a little natural sidespin.
    private func spin() async {
        guard isNewPick, skin != .original else { return }
        let start = restOrientation
        let axis = simd_normalize(SIMD3<Float>(-1, 0.22 * Float(direction), 0))
        let turns: Float = 2.5 * 2 * .pi
        // Settles just after touchdown, so the ball never keeps turning on the pad.
        let duration = 0.48
        let began = Date.now
        while !Task.isCancelled {
            let frameStart = Date.now
            let progress = min(1, frameStart.timeIntervalSince(began) / duration)
            let eased = Float(1 - (1 - progress) * (1 - progress))
            let pose = simd_normalize(simd_quatf(angle: turns * eased, axis: axis) * start)
            // Small frames while it moves; the resting pose is drawn sharp at full size.
            frame = await render(pose, moving: progress < 1)
            if progress >= 1 { restOrientation = pose; return }
            let spent = Date.now.timeIntervalSince(frameStart)
            if spent < 1.0 / 60 { try? await Task.sleep(for: .seconds(1.0 / 60 - spent)) }
        }
    }

    private func touchDown() async {
        guard isNewPick else { return }
        try? await Task.sleep(for: .seconds(Self.landing))
        if !Task.isCancelled { landings += 1 }
    }

    private func render(_ orientation: simd_quatf, moving: Bool) async -> CGImage? {
        let skin = skin
        return await Task.detached(priority: .userInitiated) {
            moving ? BallSkinSphereRenderer.previewImage(skin: skin, time: 0, orientation: orientation)
                   : BallSkinSphereRenderer.image(skin: skin, time: 0, orientation: orientation)
        }.value
    }
}

private struct Flight {
    /// 0 → 1 up the hop and back down.
    var progress: Double = 0
    /// A small straight-up rebound after touchdown.
    var hop: CGFloat = 0
    /// Uniform touchdown pulse; the ball is never drawn smaller than at rest.
    var pulse: CGFloat = 1
    /// 0 → 1 through the frost burst after touchdown.
    var impact: Double = 0
}

/// The ball pick's palette: cold, bright and glowing on the dark panel.
private enum Frost {
    static let ice = Color(red: 0.62, green: 0.92, blue: 1.0)
    static let glacier = Color(red: 0.3, green: 0.7, blue: 1.0)
    static let deep = Color(red: 0.16, green: 0.42, blue: 0.95)
}
