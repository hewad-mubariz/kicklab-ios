import SwiftUI
import UIKit
import simd

/// A ball juggling on its own above the Home stage's numbers, drawn with the app's
/// lit ball skin. Every appearance plays a new random run: soft taps, normal touches
/// and the odd high flick, drifting left and right, with spin that changes speed and
/// direction, and a lime Glow Trail behind it. Core Animation plays it outside the
/// main thread and stops it when Home leaves the screen.
struct HomeJugglingMotion: UIViewRepresentable {
    let animates: Bool

    func makeUIView(context: Context) -> HomeJugglingMotionView { HomeJugglingMotionView() }

    func updateUIView(_ view: HomeJugglingMotionView, context: Context) {
        view.animates = animates
    }
}

/// The Home balls. The juggling stage turns an app ball skin (`skin`), drawn once and
/// shared; the week's bars carry a plain classic ball (`classicBalls`).
enum HomeBallArt {
    static let skin: BallSkin = override("debug.home.ballSkin") ?? .classic

    private static var drawn: [BallSkin: [CGImage]] = [:]
    private static var tasks: [BallSkin: Task<[CGImage], Never>] = [:]

    /// Nil until drawing has been tried, so a failed draw isn't retried in a loop.
    static func frames(of skin: BallSkin) -> [CGImage]? { drawn[skin] }

    static func load(_ skin: BallSkin) async -> [CGImage] {
        if let done = drawn[skin] { return done }
        let task = tasks[skin] ?? Task.detached(priority: .utility) { () -> [CGImage] in
            // Mostly backspin, as a juggled ball turns, with a slight tilt so the seams travel.
            let axis = simd_normalize(SIMD3<Float>(1, 0.22, 0.12))
            let tilt = simd_quatf(angle: 0.35, axis: SIMD3<Float>(0, 1, 0))
            let count = 36
            return (0..<count).compactMap { step in
                let pose = simd_normalize(simd_quatf(angle: Float(step) / Float(count) * 2 * .pi, axis: axis) * tilt)
                return BallSkinSphereRenderer.previewImage(skin: skin, time: 0, orientation: pose)
            }
        }
        tasks[skin] = task
        let result = await task.value
        if drawn[skin] == nil { drawn[skin] = result }
        return drawn[skin] ?? result
    }

    // MARK: Classic ball

    private static var classic: [CGImage]?
    private static var classicTask: Task<[CGImage], Never>?

    /// Nil until drawn.
    static var classicBalls: [CGImage]? { classic }

    /// The traditional ball: black pentagons on white hexagons with thin seams, lit
    /// from the top left, in seven poses so each day's ball sits turned its own way.
    static func loadClassic() async -> [CGImage] {
        if let classic { return classic }
        let task = classicTask ?? Task.detached(priority: .utility) { () -> [CGImage] in
            (0..<7).compactMap { index in
                let turn = Float(index) * 0.9
                let pose = simd_normalize(simd_quatf(angle: 0.6 + turn, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
                    * simd_quatf(angle: 0.35 + turn * 0.4, axis: SIMD3<Float>(1, 0, 0)))
                return ClassicBall.image(pose: pose, size: 96)
            }
        }
        classicTask = task
        let drawn = await task.value
        if classic == nil { classic = drawn }
        return classic ?? drawn
    }

    private static func override(_ key: String) -> BallSkin? {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: key), let skin = BallSkin(rawValue: raw), skin != .original {
            return skin
        }
        #endif
        return nil
    }
}

/// A small lit sphere with the classic panel pattern, drawn on the CPU.
nonisolated enum ClassicBall {
    /// Twelve pentagon centres (the icosahedron's corners), then twenty hexagon centres.
    private static let sites: [SIMD3<Float>] = {
        let phi = Float((1 + sqrt(5.0)) / 2)
        var corners = [SIMD3<Float>]()
        for a: Float in [-1, 1] { for b in [-phi, phi] {
            corners += [SIMD3(0, a, b), SIMD3(a, b, 0), SIMD3(b, 0, a)]
        } }
        var faces = [SIMD3<Float>]()
        for i in 0..<corners.count { for j in (i + 1)..<corners.count { for k in (j + 1)..<corners.count {
            if abs(simd_length(corners[i] - corners[j]) - 2) < 0.001,
               abs(simd_length(corners[i] - corners[k]) - 2) < 0.001,
               abs(simd_length(corners[j] - corners[k]) - 2) < 0.001 {
                faces.append(simd_normalize(corners[i] + corners[j] + corners[k]))
            }
        } } }
        return corners.map(simd_normalize) + faces
    }()

    static func image(pose: simd_quatf, size: Int) -> CGImage? {
        let light = simd_normalize(SIMD3<Float>(-0.45, 0.62, 0.65))
        let inverse = pose.inverse
        let radius = Float(size) / 2
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for py in 0..<size { for px in 0..<size {
            let x = (Float(px) + 0.5 - radius) / radius, y = (radius - Float(py) - 0.5) / radius
            let distance = sqrt(x * x + y * y)
            let coverage = max(0, min(1, (1 - distance) * radius))
            guard coverage > 0 else { continue }
            let normal = SIMD3(x, y, sqrt(max(0, 1 - x * x - y * y)))
            let object = inverse.act(normal)
            var best: Float = -2, second: Float = -2, bestIndex = 0
            for (index, site) in sites.enumerated() {
                let closeness = simd_dot(object, site)
                if closeness > best { second = best; best = closeness; bestIndex = index }
                else if closeness > second { second = closeness }
            }
            let pentagon = bestIndex < 12
            let seam = max(0, min(1, (best - second) / 0.012))
            // Seams darken the panel edges into thin grey lines.
            let albedo: Float = (pentagon ? 0.07 : 0.95) * (0.55 + 0.45 * seam)
            let diffuse = max(0, simd_dot(normal, light))
            let halfway = simd_normalize(light + SIMD3<Float>(0, 0, 1))
            let shine = pow(max(0, simd_dot(normal, halfway)), 36) * (pentagon ? 0.35 : 0.5)
            let rim = 0.78 + 0.22 * normal.z
            let tone = min(1, (albedo * (0.32 + 0.78 * diffuse) + shine) * rim)
            let value = UInt8((sqrt(tone) * coverage * 255).rounded())
            let offset = (py * size + px) * 4
            rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value
            rgba[offset + 3] = UInt8((coverage * 255).rounded())
        } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

final class HomeJugglingMotionView: UIView {
    var animates = false { didSet { if animates != oldValue { rebuild() } } }

    /// Where the foot meets the ball, in points from the stage's top: just above the
    /// bottom of the stage's fixed-height top area. The ball keeps to the right of the
    /// best streak, between `minX` and `maxX`, and below `topLimit`.
    private static let ground: CGFloat = 178
    private static let topLimit: CGFloat = 40
    private static let homeX: CGFloat = 0.72
    private static let minX: CGFloat = 0.6
    private static let maxX: CGFloat = 0.86
    private static let ballSize: CGFloat = 50
    private static let hopsPerRun = 22
    private static let lime = UIColor(red: 0xD0 / 255, green: 0xF8 / 255, blue: 0x52 / 255, alpha: 1)

    private let pitch = CAShapeLayer()
    private let shadow = CALayer()
    /// The app's Glow Trail, in lime: a wide soft halo, a body that tapers to a
    /// point, and a near-white core. Each band follows the ball for its own time,
    /// so together they narrow away from it.
    private struct TrailBand {
        let size: CGFloat
        let count: Int
        let delay: Double
        let color: UIColor
        let alpha: CGFloat
        let hardness: CGFloat
    }
    private static let bands: [TrailBand] = [
        // Points sit closer than their size even at the fastest kick, so each band reads as one stroke.
        TrailBand(size: 46, count: 18, delay: 0.011, color: UIColor(red: 0.30, green: 0.86, blue: 0.12, alpha: 1), alpha: 0.18, hardness: 0.1),
        TrailBand(size: 22, count: 34, delay: 0.01, color: UIColor(red: 0.50, green: 0.96, blue: 0.20, alpha: 1), alpha: 0.6, hardness: 0.45),
        TrailBand(size: 12, count: 76, delay: 0.007, color: UIColor(red: 0.70, green: 0.98, blue: 0.30, alpha: 1), alpha: 0.5, hardness: 0.5),
        TrailBand(size: 6, count: 70, delay: 0.005, color: UIColor(red: 0.95, green: 1, blue: 0.86, alpha: 1), alpha: 0.85, hardness: 0.6),
    ]
    private let trails: [CAReplicatorLayer] = HomeJugglingMotionView.bands.map { _ in CAReplicatorLayer() }
    private let trailDots: [CALayer] = HomeJugglingMotionView.bands.map { _ in CALayer() }
    private let trailGroup = CALayer()
    /// Small puffs of dust where the ball comes down; rebuilt with each run.
    private let dust = CALayer()
    /// Carries position and squash; `face` inside it carries the spin.
    private let ball = CALayer()
    private let face = CALayer()
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pitch.fillColor = nil
        pitch.strokeColor = UIColor.white.withAlphaComponent(0.08).cgColor
        pitch.lineWidth = 1.5

        shadow.bounds = CGRect(x: 0, y: 0, width: 64, height: 16)
        shadow.contents = Self.softDot(color: .black, size: CGSize(width: 64, height: 16), alpha: 0.75).cgImage

        for (band, (trail, dot)) in zip(Self.bands, zip(trails, trailDots)) {
            dot.bounds = CGRect(x: 0, y: 0, width: band.size, height: band.size)
            dot.contents = Self.softDot(color: band.color, size: dot.bounds.size, alpha: band.alpha,
                                        hardness: band.hardness).cgImage
            trail.instanceCount = band.count
            trail.instanceDelay = band.delay
            trail.instanceAlphaOffset = -1 / Float(band.count)
            trail.addSublayer(dot)
            trailGroup.addSublayer(trail)
        }

        let box = CGRect(x: 0, y: 0, width: Self.ballSize, height: Self.ballSize)
        ball.bounds = box
        ball.shadowColor = Self.lime.cgColor
        ball.shadowOpacity = 0.3
        ball.shadowRadius = 14
        ball.shadowOffset = .zero
        ball.shadowPath = UIBezierPath(ovalIn: box).cgPath
        face.frame = box
        face.contentsGravity = .resizeAspect
        ball.addSublayer(face)

        [pitch, shadow, dust, trailGroup, ball].forEach(layer.addSublayer)
        // Backgrounding removes running layer animations.
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        ([pitch, dust, trailGroup] + trails).forEach { $0.frame = bounds }
        face.contentsScale = traitCollection.displayScale
        rebuild()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A new run each time Home comes back.
        rebuild()
    }

    // MARK: Run

    private struct Hop {
        let x: CGFloat
        let rise: CGFloat
        let turns: Double
    }

    /// Mostly normal touches, some soft taps, now and then a high flick. The ball
    /// wanders but is pulled back to the centre spot, where the last hop lands so
    /// the run loops without a jump.
    private static func randomRun() -> [Hop] {
        let maxRise = ground - topLimit
        var hops: [Hop] = []
        var x = homeX
        var spin = -1.0
        for index in 0..<hopsPerRun {
            let roll = Double.random(in: 0..<1)
            let rise: CGFloat = roll < 0.24 ? .random(in: 30...46)
                : roll < 0.86 ? .random(in: 62...98) : .random(in: 104...maxRise)
            var next = x + .random(in: -0.08...0.08) + (homeX - x) * 0.35
            next = min(maxX, max(minX, next))
            if index == hopsPerRun - 1 { next = homeX }
            if Double.random(in: 0..<1) < 0.22 { spin = -spin }
            hops.append(Hop(x: next, rise: rise, turns: spin * .random(in: 0.2...0.7)))
            x = next
        }
        return hops
    }

    private static func duration(rise: CGFloat) -> Double {
        0.6 * sqrt(Double(rise) / 110)
    }

    // MARK: Build

    @objc private func rebuild() {
        ([ball, face, shadow] + trailDots).forEach { $0.removeAllAnimations() }
        dust.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard laidOutSize != .zero else { return }
        let width = bounds.width
        let ground = Self.ground
        let frames = HomeBallArt.frames(of: HomeBallArt.skin) ?? []
        if HomeBallArt.frames(of: HomeBallArt.skin) == nil {
            Task { [weak self] in
                _ = await HomeBallArt.load(HomeBallArt.skin)
                self?.rebuild()
            }
        }

        let rest = CGPoint(x: width * Self.homeX, y: ground - 80)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pitch.path = UIBezierPath(ovalIn: CGRect(x: width * Self.homeX - width * 0.24, y: ground + 8,
                                                 width: width * 0.48, height: 30)).cgPath
        face.contents = frames.first ?? Self.fallbackBall.cgImage
        ball.position = rest
        ball.transform = CATransform3DIdentity
        trailDots.forEach { $0.position = rest }
        shadow.position = CGPoint(x: rest.x, y: ground + 32)
        shadow.transform = CATransform3DMakeScale(0.62, 0.62, 1)
        shadow.opacity = 0.35
        trailGroup.isHidden = !animates
        CATransaction.commit()
        guard animates, window != nil else { return }

        let hops = Self.randomRun()
        // Whole turns over the run, so the spin also loops without a jump.
        let turns = hops.map(\.turns).reduce(0, +)
        let correction = (turns.rounded() - turns) / Double(hops.count)
        let frameCount = Double(max(frames.count, 1))

        var times: [Double] = []
        var positions: [NSValue] = []
        var squash: [NSValue] = []
        var faces: [Any] = []
        var shadowPositions: [NSValue] = []
        var shadowScales: [Double] = []
        var shadowOpacity: [Double] = []
        var impacts: [(x: CGFloat, time: Double, fall: CGFloat, drift: CGFloat)] = []
        var x = width * Self.homeX, time = 0.0, phase = 0.0
        // The first landing ends the run's last hop.
        var fall = hops.last?.rise ?? 90
        var drift = hops.count > 1 ? width * (hops[hops.count - 1].x - hops[hops.count - 2].x) : 0

        func sample(at point: CGPoint, time: Double, contact: Bool, speed: Double) {
            times.append(time)
            positions.append(NSValue(cgPoint: point))
            let stretch = 0.07 * speed * speed
            squash.append(NSValue(caTransform3D: contact ? CATransform3DMakeScale(1.14, 0.86, 1)
                                  : CATransform3DMakeScale(1 - stretch * 0.7, 1 + stretch, 1)))
            let height = Double(ground - point.y) / Double(Self.ground - Self.topLimit)
            shadowPositions.append(NSValue(cgPoint: CGPoint(x: point.x, y: ground + 32)))
            shadowScales.append(1 - 0.5 * height)
            shadowOpacity.append(0.55 - 0.35 * height)
            if !frames.isEmpty {
                let index = Int(phase.rounded(.down)) % frames.count
                faces.append(frames[(index + frames.count) % frames.count])
            }
        }

        for hop in hops {
            let rise = hop.rise
            let duration = Self.duration(rise: rise)
            let next = width * hop.x
            let spin = (hop.turns + correction) * frameCount
            impacts.append((x, time, fall, drift))
            fall = rise
            drift = next - x
            let samples = 30
            for index in 0..<samples {
                let s = Double(index) / Double(samples)
                let point = CGPoint(x: x + (next - x) * s, y: ground - 4 * rise * s * (1 - s))
                sample(at: point, time: time + duration * s, contact: index == 0, speed: abs(1 - 2 * s))
                phase += spin / Double(samples)
            }
            time += duration
            x = next
        }
        sample(at: CGPoint(x: x, y: ground), time: time, contact: true, speed: 1)
        let keyTimes = times.map { NSNumber(value: $0 / time) }
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.05

        func keyframes(_ path: String, _ values: [Any], mode: CAAnimationCalculationMode = .linear) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: path)
            animation.values = values
            // A discrete animation has one more key time than values.
            animation.keyTimes = mode == .discrete ? keyTimes : Array(keyTimes.prefix(values.count))
            animation.calculationMode = mode
            return animation
        }
        func loop(_ animations: [CAAnimation], on target: CALayer, key: String) {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = time
            group.repeatCount = .infinity
            group.beginTime = begin
            group.fillMode = .backwards
            target.add(group, forKey: key)
        }

        loop([keyframes("position", positions), keyframes("transform", squash)], on: ball, key: "juggle")
        trailDots.forEach { loop([keyframes("position", positions)], on: $0, key: "juggle") }
        loop([keyframes("position", shadowPositions), keyframes("transform.scale", shadowScales),
              keyframes("opacity", shadowOpacity)], on: shadow, key: "juggle")
        if !faces.isEmpty {
            loop([keyframes("contents", Array(faces.dropLast()), mode: .discrete)], on: face, key: "spin")
        }

        // Dust, kept uneven like the real thing: soft taps mostly raise nothing,
        // harder landings a faint cloud that rises and drifts the way the ball was
        // travelling, plus a few grains that hop up and fall back. A light wind
        // carries all of it the same way for the whole run.
        let puffs = Self.puffImages
        guard !puffs.isEmpty else { return }
        let wind: CGFloat = (Bool.random() ? 1 : -1) * .random(in: 3...9)
        let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.35, 1)
        let flat = CAMediaTimingFunction(name: .linear)

        /// Values across one moment of the loop, holding still before and after it.
        func moment(_ path: String, start: Double, end: Double, _ points: [(Double, Any)],
                    curve: CAMediaTimingFunction) -> CAKeyframeAnimation {
            var values: [Any] = [], keys: [Double] = [], curves: [CAMediaTimingFunction] = []
            if start > 0.0005 { values.append(points[0].1); keys.append(0) }
            for (index, point) in points.enumerated() {
                if !values.isEmpty { curves.append(index == 0 ? flat : curve) }
                values.append(point.1); keys.append(start + (end - start) * point.0)
            }
            if keys[keys.count - 1] < 0.9995 { values.append(points[points.count - 1].1); keys.append(1); curves.append(flat) }
            keys[0] = 0
            let animation = CAKeyframeAnimation(keyPath: path)
            animation.values = values
            animation.keyTimes = keys.map { NSNumber(value: $0) }
            animation.timingFunctions = curves
            return animation
        }

        for impact in impacts {
            let strength = min(1, max(0.2, impact.fall / (Self.ground - Self.topLimit)))
            if Double.random(in: 0..<1) < (strength < 0.45 ? 0.6 : 0.15) { continue }
            let start = impact.time / time
            let heading: CGFloat = abs(impact.drift) < 4 ? (Bool.random() ? 1 : -1) : (impact.drift > 0 ? 1 : -1)
            let floor = ground + 27

            for _ in 0..<Int.random(in: 1...(strength > 0.7 ? 4 : 2)) {
                // Most of the cloud follows the ball's heading; a little goes back.
                let side = Double.random(in: 0..<1) < 0.75 ? heading : -heading
                let width = CGFloat.random(in: 22...36) * (0.7 + 0.5 * strength)
                let origin = CGPoint(x: impact.x + .random(in: -7...7), y: floor + .random(in: -2...2))
                let reach = side * .random(in: 6...26) * strength
                let lift = CGFloat.random(in: 8...24) * strength
                let middle = CGPoint(x: origin.x + reach * 0.7 + wind * 0.3 + .random(in: -4...4), y: origin.y - lift * 0.55)
                let target = CGPoint(x: origin.x + reach + wind, y: origin.y - lift)
                let end = min(0.999, (impact.time + .random(in: 0.8...1.3)) / time)
                let puff = CALayer()
                puff.bounds = CGRect(x: 0, y: 0, width: width, height: width * 0.72)
                puff.contents = puffs.randomElement()
                puff.position = origin
                puff.opacity = 0
                dust.addSublayer(puff)
                let peak = Float.random(in: 0.14...0.26) * Float(0.6 + 0.4 * strength)
                let grow = Double.random(in: 1.6...2.4)
                loop([moment("position", start: start, end: end,
                             [(0, NSValue(cgPoint: origin)), (0.35, NSValue(cgPoint: middle)), (1, NSValue(cgPoint: target))], curve: ease),
                      moment("transform.scale", start: start, end: end, [(0, 0.4), (1, grow)], curve: ease),
                      moment("transform.rotation.z", start: start, end: end,
                             [(0, 0.0), (1, Double.random(in: -0.4...0.4))], curve: ease),
                      moment("opacity", start: start, end: end,
                             [(0, Float(0)), (0.08, peak), (0.45, peak * 0.7), (1, Float(0))], curve: flat)],
                     on: puff, key: "dust")
            }

            // Grains: tiny specks thrown up in short arcs, mostly forward.
            for _ in 0..<Int.random(in: 0...(strength > 0.6 ? 4 : 2)) {
                let side = Double.random(in: 0..<1) < 0.7 ? heading : -heading
                let grain = CALayer()
                let size = CGFloat.random(in: 1.5...2.6)
                grain.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                grain.cornerRadius = size / 2
                grain.backgroundColor = UIColor(red: 0.86, green: 0.88, blue: 0.8, alpha: 1).cgColor
                grain.opacity = 0
                let origin = CGPoint(x: impact.x + .random(in: -6...6), y: floor)
                let run = side * .random(in: 8...38) * strength
                let height = CGFloat.random(in: 5...18) * strength
                let flight = Double.random(in: 0.28...0.48)
                let end = min(0.999, (impact.time + flight) / time)
                let arc: [(Double, Any)] = (0...8).map { step in
                    let u = Double(step) / 8
                    return (u, NSValue(cgPoint: CGPoint(x: origin.x + run * CGFloat(u),
                                                        y: origin.y - 4 * height * CGFloat(u * (1 - u)))))
                }
                dust.addSublayer(grain)
                loop([moment("position", start: start, end: end, arc, curve: flat),
                      moment("opacity", start: start, end: end,
                             [(0, Float(0)), (0.06, Float(0.75)), (0.7, Float(0.5)), (1, Float(0))], curve: flat)],
                     on: grain, key: "grain")
            }
        }
    }

    // MARK: Art

    /// Irregular soft clouds in the floodlit pitch's pale dust colour.
    private static let puffImages: [CGImage] = (0..<4).compactMap { _ in
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colour = UIColor(red: 0.84, green: 0.87, blue: 0.78, alpha: 1)
            let colors = [colour.withAlphaComponent(0.32).cgColor, colour.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            for _ in 0..<10 {
                let radius = CGFloat.random(in: 12...22)
                let centre = CGPoint(x: 32 + .random(in: -10...10), y: 32 + .random(in: -6...6))
                context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                                     endRadius: radius, options: [])
            }
        }
        return image.cgImage
    }

    /// Used only until the skin's frames are ready, or if they can't be drawn.
    private static let fallbackBall: UIImage = {
        let size = ballSize
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.92, weight: .regular)
            guard let symbol = UIImage(systemName: "soccerball", withConfiguration: config)?
                .withTintColor(.black, renderingMode: .alwaysOriginal) else { return }
            symbol.draw(in: CGRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
    }()

    /// A round glow; `hardness` keeps the centre solid for that share of the radius.
    private static func softDot(color: UIColor, size: CGSize, alpha: CGFloat, hardness: CGFloat = 0) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(alpha * 0.85).cgColor,
                          color.withAlphaComponent(0).cgColor] as CFArray
            let locations: [CGFloat] = [0, max(0.01, hardness), 1]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else { return }
            let cg = context.cgContext
            cg.scaleBy(x: 1, y: size.height / size.width)
            let center = CGPoint(x: size.width / 2, y: size.width / 2)
            cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                  endRadius: size.width / 2, options: [])
        }
    }
}
