import SwiftUI
import simd

/// Picking a ball plays like a trick. It leaves its spot and swings round a loop that
/// comes toward you (bigger at the top, never smaller than at rest), tumbling on its
/// real printed panels with a glowing ice trail behind it while its shadow shrinks below.
/// It lands in a frost burst (ground ripples, a flash and flying ice shards) and the
/// ice pad under it lights up. Reduce Motion keeps the lit pad, without the flight.
struct BallPickSlot: View {
    let skin: BallSkin
    let selected: Bool
    /// Bumped on every pick of this ball; each change plays the moment once.
    let picks: Int
    var size: CGFloat = 62
    /// 1 swings out to the right first, -1 to the left, so edge columns swing inward.
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
                    trail(flight.progress)
                    flightGlow(spot)
                    ball
                        .frame(width: size, height: size)
                        .scaleEffect((1 + 0.5 * spot.depth) * flight.pulse)
                        .rotationEffect(.degrees(-28 * Double(direction) * sin(flight.progress * 2 * .pi)
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
        .task(id: skin) { if frame == nil { frame = await render(restOrientation, moving: false) } }
        .task(id: picks) { await spin() }
        .task(id: picks) { await touchDown() }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: landings)
    }

    /// The swing, in slot points: up and right, over the top, down the left, back in.
    /// Depth is how close it has come toward the viewer, highest at the top of the loop.
    private func loop(_ progress: Double) -> (point: CGPoint, depth: Double) {
        let angle = progress * 2 * .pi
        return (CGPoint(x: direction * size * 1.0 * sin(angle), y: -size * 0.62 * (1 - cos(angle))),
                max(0, sin(angle / 2)))
    }

    @ViewBuilder private var ball: some View {
        if skin == .original {
            Image(systemName: "soccerball").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.75))
        } else if let frame {
            Image(decorative: frame, scale: 1).resizable().scaledToFit().padding(size * 0.035)
        } else {
            Color.clear
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

    /// A glowing ice trail along the path just travelled: soft blue glow, an ice body,
    /// a white-hot core and frost sparkles twinkling off its tail.
    private func trail(_ head: Double) -> some View {
        let tail = max(0, head - 0.4), steps = 18
        func at(_ step: Int) -> (point: CGPoint, depth: Double) {
            let spot = loop(tail + (head - tail) * Double(step) / Double(steps))
            return (CGPoint(x: spot.point.x + size / 2, y: spot.point.y + size / 2), spot.depth)
        }
        func segment(_ step: Int) -> Path {
            Path { path in path.move(to: at(step - 1).point); path.addLine(to: at(step).point) }
        }
        func width(_ step: Int) -> CGFloat {
            (1.5 + 7 * Double(step) / Double(steps)) * (1 + 0.5 * at(step).depth)
        }
        return ZStack {
            ZStack {
                ForEach(1...steps, id: \.self) { step in
                    segment(step).stroke(Frost.glacier.opacity(0.7 * Double(step) / Double(steps)),
                                         style: StrokeStyle(lineWidth: width(step) * 2.6, lineCap: .round))
                }
            }
            .blur(radius: 7)
            .blendMode(.plusLighter)
            ForEach(1...steps, id: \.self) { step in
                let fraction = Double(step) / Double(steps)
                segment(step).stroke(Frost.ice.opacity(0.85 * fraction),
                                     style: StrokeStyle(lineWidth: width(step), lineCap: .round))
                segment(step).stroke(.white.opacity(0.9 * fraction * fraction),
                                     style: StrokeStyle(lineWidth: width(step) * 0.32, lineCap: .round))
            }
            ForEach(0..<9, id: \.self) { index in
                let fraction = (Double(index) + 0.5) / 9
                let spot = at(Int((fraction * Double(steps)).rounded()))
                let drift = sin(Double(index) * 12.9898) * size * 0.14
                Image(systemName: "sparkle")
                    .font(.system(size: 5 + 4 * fraction, weight: .bold))
                    .foregroundStyle(index.isMultiple(of: 3) ? .white : Frost.ice)
                    .shadow(color: Frost.glacier, radius: 3)
                    .position(x: spot.point.x + drift * 0.6, y: spot.point.y + drift)
                    .opacity((0.35 + 0.65 * abs(sin(head * 38 + Double(index) * 1.7))) * fraction)
            }
        }
        .frame(width: size, height: size)
        .opacity(head > 0.02 && head < 0.995 ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// The ball runs cold while it flies: an ice glow that grows as it comes toward you.
    private func flightGlow(_ spot: (point: CGPoint, depth: Double)) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Frost.ice.opacity(0.6), Frost.glacier.opacity(0.28), .clear],
                                 center: .center, startRadius: 0, endRadius: size * 0.75))
            .frame(width: size * 1.5, height: size * 1.5)
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
                let width = size * (0.95 + 1.6 * wave)
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
                let speed = size * (1.5 + 0.7 * Double((index * 7) % 5) / 4)
                let t = impact
                // Launched from the rim of the pad, clear of the ball itself.
                let x = cos(angle) * (size * 0.36 + speed * t)
                let y = sin(angle) * speed * t + 0.5 * size * 3.4 * t * t
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
    /// 0 → 1 around the loop.
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
