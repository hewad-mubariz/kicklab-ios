import AVFoundation
import CoreGraphics
import Metal
import Vision

/// The frozen contact moment as a few flat pieces in 3D, enough to swing a camera a little way
/// around the kicker: grass on the ground, the goal and trees as a backdrop, the kicker as a cut-out
/// standing where his feet meet the grass.
///
/// Distances come from the picture itself, so imported videos work too: the ball (22 cm) at the
/// kicker's foot says how far away he is, people boxes at different distances find the ground and
/// the horizon, and how small the ball gets by the net places the backdrop. Rough is fine: a 30%
/// error in the backdrop's distance changes how far it slides by a few pixels.
nonisolated struct ShotArcScene: Equatable, Sendable {
    /// Focal length, in picture widths.
    var focal: Double
    /// The horizon row, in picture widths from the top (rows below it are grass).
    var horizon: Double
    /// The kicker's column at contact, 0 – 1 across the picture.
    var pivotX: Double
    /// Metres: the phone above the grass, and the kicker and the backdrop in front of it.
    var cameraHeight: Double
    var kickerDepth: Double
    var backdropDepth: Double
    /// True when the ground came from people seen at several distances, not the fallback guess.
    var fitted: Bool

    static let ballRadius = 0.11, personHeight = 1.7

    /// The swung camera at one moment. Pixels are those of a `width` × `height` picture.
    struct View: Equatable, Sendable {
        var eye: SIMD3<Double>
        var cos: Double, sin: Double
        var focal: Double
        /// The view's centre, which the framing moves to stay on the recorded picture.
        var centerX: Double, centerY: Double
    }

    /// The camera swung by `swing` (radians) about the kicker and pushed in by `push`, then panned
    /// and zoomed just enough that everything it shows is something the phone filmed: no edge of the
    /// picture has to be invented (mirrored) from inside it.
    func view(swing: Double, push: Double, width: Double, height: Double) -> View {
        let pivot = (pivotX - 0.5) * kickerDepth / focal
        let ex = -pivot, ez = -kickerDepth
        let c = Foundation.cos(swing), s = Foundation.sin(swing)
        let eye = SIMD3(pivot + c * ex + s * ez, cameraHeight, kickerDepth - s * ex + c * ez)
        var view = View(eye: eye, cos: c, sin: s, focal: focal * width * push, centerX: 0.5 * width, centerY: horizon * width)
        for _ in 0..<8 {
            let out = overflow(of: view, width: width, height: height)
            guard out.left + out.right + out.top + out.bottom > 0.25 else { break }
            let zoom = view.focal / (focal * width)
            // Zoom in by the share that spills over, and slide the view toward the side with picture left.
            let grow = max(width / max(1, width - out.left - out.right), height / max(1, height - out.top - out.bottom))
            view.centerX -= (out.left - out.right) / 2 * zoom
            view.centerY -= (out.top - out.bottom) / 2 * zoom
            view.focal = min(focal * width * 2, view.focal * grow * 1.002)
        }
        return view
    }

    /// The widest swing, up to `limit`, that stays on the recorded picture with at most `maxZoom`.
    func coveredSwing(upTo limit: Double, width: Double, height: Double, maxZoom: Double = 1.3) -> Double {
        func fits(_ swing: Double) -> Bool {
            [swing, -swing].allSatisfy { view(swing: $0, push: 1, width: width, height: height).focal <= focal * width * maxZoom }
        }
        if fits(limit) { return limit }
        var lo = 0.0, hi = limit
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// How far past each edge of the recorded picture the view reaches, in pixels. Only what would
    /// show a doubled copy counts: the backdrop (goal, fence, trees) and the pitch from the kicker
    /// outward. Grass close to the lens is plain texture; borrowing it from nearby is invisible.
    func overflow(of view: View, width: Double, height: Double) -> (left: Double, right: Double, top: Double, bottom: Double) {
        var out = (left: 0.0, right: 0.0, top: 0.0, bottom: 0.0)
        let steps = (0...8).map { Double($0) / 8 }
        let border = steps.flatMap { k in [(k * width, 0.0), (k * width, height), (0.0, k * height), (width, k * height)] }
        for (x, y) in border {
            guard let p = seen(x, y, from: view, width: width, nearest: kickerDepth * 0.8) else { continue }
            out.left = max(out.left, -p.x); out.right = max(out.right, p.x - width)
            out.top = max(out.top, -p.y); out.bottom = max(out.bottom, p.y - height)
        }
        return out
    }

    /// Where the phone saw what the swung camera sees through pixel (x, y): the grass, or the backdrop
    /// beyond it. The same geometry as the shader's frozen-arc mode.
    func seen(_ x: Double, _ y: Double, from view: View, width: Double, nearest: Double = 0) -> SIMD2<Double>? {
        let a = (x - view.centerX) / view.focal, b = -(y - view.centerY) / view.focal
        let dx = view.cos * a + view.sin, dy = b, dz = -view.sin * a + view.cos
        let tg = dy < -1e-5 ? -view.eye.y / dy : Double.infinity
        let tb = dz > 1e-5 ? (backdropDepth - view.eye.z) / dz : Double.infinity
        let t = view.eye.z + dz * tg <= backdropDepth ? tg : tb
        guard t.isFinite, view.eye.z + dz * t >= nearest else { return nil }
        let qx = view.eye.x + dx * t, qy = view.eye.y + dy * t, qz = max(0.05, view.eye.z + dz * t)
        let f = focal * width
        return SIMD2(0.5 * width + f * qx / qz, horizon * width + f * (cameraHeight - qy) / qz)
    }

    static func solve(ball: BallEffectTrack, strike: Double, flightEnd: Double, aspect: Double) -> ShotArcScene {
        let aspect = max(0.1, aspect)
        // A phone's main camera sees about 67° across its long side.
        let focal = 0.752 * max(1, 1 / aspect)
        func radius(_ s: BallStyleSample) -> Double {
            guard let box = s.boxSize else { return Double(s.radius) }
            return min(Double(box.width), Double(box.height) / aspect) / 2
        }
        func median(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
        let seen = ball.samples.filter { $0.confidence >= 0.3 }

        // The ball resting at the kicker's foot just before contact sizes everything near him.
        let resting = seen.filter { $0.time >= strike - 0.3 && $0.time <= strike + 0.001 }
        let restRadius = median(resting.map(radius)) ?? median(seen.prefix(8).map(radius)) ?? 0.03
        let atContact = resting.last ?? ball.sample(at: strike)
        let ballX = atContact.map { Double($0.center.x) } ?? 0.5
        let ballBottom = (atContact.map { Double($0.center.y) } ?? 0.75) / aspect + restRadius
        let kicker = ball.person(at: strike)
        // The ball says how far away the kicker is when it sits at his feet. When it does not (the
        // strike was missed), his own height in the picture says it instead.
        let atFeet = kicker.map { box in
            abs(ballX - box.x) < box.width * 0.75 + 0.03 && abs(ballBottom * aspect - box.bottom) < box.height * 0.3 + 0.03
        } ?? true
        let byBall = focal * ballRadius / max(0.002, restRadius)
        let byHeight = kicker.map { focal * personHeight / max(0.02, $0.height / aspect) }
        let kickerDepth = min(30, max(0.6, atFeet ? byBall : byHeight ?? byBall))
        let pivotX = kicker.map { atFeet ? 0.6 * $0.x + 0.4 * ballX : $0.x } ?? ballX

        // Feet on the grass: row = horizon + phone height × focal / distance. A person's distance comes
        // from their height in the picture, the ball's from its size, so every sighting is one point on
        // that line: row against (picture height / real height).
        var points: [(k: Double, row: Double, weight: Double)] = []
        for sample in ball.people {
            let box = sample.box
            let top: Double = box.y - box.height / 2
            let left: Double = box.x - box.width / 2, right: Double = box.x + box.width / 2
            let upright: Bool = box.height > 1.3 * max(0.001, box.width)
            // Whole people only: one cut off by the picture's edge has no true height.
            guard box.height > 0.06, top > 0.01, box.bottom < 0.99, left > 0.005, right < 0.995, upright else { continue }
            let k: Double = box.height / aspect / personHeight
            points.append((k: k, row: box.bottom / aspect, weight: 1))
        }
        let people = points.count
        if atFeet { points.append((k: restRadius / ballRadius, row: ballBottom, weight: Double(max(4, people / 3)))) }
        func fit(_ points: [(k: Double, row: Double, weight: Double)]) -> (horizon: Double, height: Double)? {
            let w = points.reduce(0) { $0 + $1.weight }
            guard w > 0 else { return nil }
            let mk = points.reduce(0) { $0 + $1.weight * $1.k } / w, mr = points.reduce(0) { $0 + $1.weight * $1.row } / w
            let skk = points.reduce(0) { $0 + $1.weight * ($1.k - mk) * ($1.k - mk) }
            let skr = points.reduce(0) { $0 + $1.weight * ($1.k - mk) * ($1.row - mr) }
            guard skk > 1e-9 else { return nil }
            let height = skr / skk
            return (mr - height * mk, height)
        }
        var ground: (horizon: Double, height: Double)?
        let ks = points.prefix(people).map(\.k)
        if people >= 6, let lo = ks.min(), let hi = ks.max(), hi / max(1e-6, lo) > 1.4, var first = fit(points) {
            // One pass of outlier rejection: running poses and partly hidden people miss the line.
            let residuals = points.map { abs($0.row - (first.horizon + first.height * $0.k)) }
            let typical = max(0.004, median(residuals) ?? 0)
            let kept = zip(points, residuals).filter { $0.1 <= typical * 3 }.map(\.0)
            if kept.count >= 5, let refit = fit(kept) { first = refit }
            if first.height > 0.12, first.height < 2.6, first.horizon > -0.3 / aspect, first.horizon < ballBottom - 0.01 || !atFeet {
                ground = first
            }
        }
        // Without enough people at different distances, the horizon is taken a little above the middle
        // (where it sits when a phone films a pitch, on the grass or in a hand), and the phone's height
        // follows from where the kicker's feet meet the grass.
        let feetRow = atFeet ? ballBottom : kicker.map { $0.bottom / aspect } ?? ballBottom
        var cameraHeight = ground?.height ?? min(1.8, max(0.25, (feetRow - 0.45 / aspect) * kickerDepth / focal))
        var horizon = ground?.horizon ?? (feetRow - cameraHeight * focal / kickerDepth)
        if !cameraHeight.isFinite || !horizon.isFinite { cameraHeight = 0.45; horizon = 0.45 / aspect }

        // The backdrop stands about where the ball ends its flight.
        let landingStart: Double = max(flightEnd - 0.25, strike + 0.15), landingEnd: Double = flightEnd + 0.05
        let landing = seen.filter { $0.time >= landingStart && $0.time <= landingEnd }
        var backdrop = median(landing.map(radius)).map { focal * ballRadius / max(0.002, $0) * 1.05 } ?? kickerDepth * 5
        backdrop = min(60, max(kickerDepth + 3, backdrop))
        return ShotArcScene(focal: focal, horizon: horizon, pivotX: min(0.95, max(0.05, pivotX)), cameraHeight: cameraHeight,
                            kickerDepth: kickerDepth, backdropDepth: backdrop, fitted: ground != nil)
    }
}

/// The frozen frame split for Frozen Arc: the background with the kicker painted out from other
/// frames (rgb), and the kicker's outline (alpha). BGRA, straight alpha, top row first.
nonisolated final class ShotArcLayers: @unchecked Sendable {
    let bytes: [UInt8]
    let width: Int, height: Int
    /// The source moment the layers were cut at: the frozen frame.
    let time: Double
    /// Whether Vision's person mask shaped the kicker's outline (it can come back empty).
    let usedVision: Bool
    private var texture: MTLTexture?
    private let lock = NSLock()

    init(bytes: [UInt8], width: Int, height: Int, time: Double, usedVision: Bool = true) {
        self.bytes = bytes; self.width = width; self.height = height; self.time = time; self.usedVision = usedVision
    }

    func matches(_ moment: Double?) -> Bool { moment.map { abs($0 - time) < 0.0005 } ?? false }

    func texture(device: MTLDevice) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let texture, texture.device === device { return texture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let made = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { made.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                             withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        texture = made
        return made
    }

    /// Cuts the layers at `time` from the upright source video. `knownMask` (a person mask of that
    /// frame, white on black) stands in for Vision, which the iOS Simulator cannot run.
    @concurrent static func build(source: URL, ball: BallEffectTrack, time: Double, shortEdge: Int = 720,
                      knownMask: CGImage? = nil) async throws -> ShotArcLayers? {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: shortEdge * 4, height: shortEdge * 4)
        let duration = try await asset.load(.duration).seconds
        let frozenImage = try await generator.image(at: CMTime(seconds: time + 0.000001, preferredTimescale: 1_800_000_000)).image
        let scale = min(1, Double(shortEdge) / Double(min(frozenImage.width, frozenImage.height)))
        let width = max(2, Int(Double(frozenImage.width) * scale)), height = max(2, Int(Double(frozenImage.height) * scale))
        guard let frozen = Picture(frozenImage, width: width, height: height) else { return nil }

        // Where the kicker is: his box at contact, grown a little, and the ball at his foot.
        let box = ball.person(at: time)
        let ballNow = ball.sample(at: time)
        let ballDisc = ballNow.flatMap { sample in sample.boxSize.map { size in
            (x: Double(sample.center.x) * Double(width), y: Double(sample.center.y) * Double(height),
             r: min(Double(size.width) * Double(width), Double(size.height) * Double(height)) / 2)
        } }
        var region = [Bool](repeating: false, count: width * height)
        var ballCover = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width), i = y * width + x
                if let box { region[i] = abs(u - box.x) <= box.width * 0.62 + 0.02 && abs(v - box.y) <= box.height * 0.56 + 0.02 }
                if let ballDisc {
                    let dx: Double = Double(x) + 0.5 - ballDisc.x, dy: Double = Double(y) + 0.5 - ballDisc.y
                    let d: Double = (dx * dx + dy * dy).squareRoot()
                    if d < ballDisc.r + 1 { ballCover[i] = Float(min(1, max(0, (ballDisc.r + 1 - d) / 2))); region[i] = true }
                }
            }
        }
        // Vision's person mask, kept to that box.
        var vision = knownMask.flatMap { resampled($0, width: width, height: height) }
            ?? personMask(frozenImage, around: box, width: width, height: height) ?? [Float](repeating: 0, count: width * height)
        if box != nil { for i in 0..<vision.count where !region[i] { vision[i] = 0 } }
        // Without Vision's mask (it can come back empty), the kicker's box alone says where to look.
        let seenByVision = vision.contains(where: { $0 > 0.5 })
        guard seenByVision || box != nil else { return nil }

        // A clean background for the whole box, and for anything Vision found beside it.
        let grow = max(4, width / 60)
        let gate = dilate(zip(region, vision).map { $0 || $1 > 0.08 }, width: width, height: height, radius: grow)
        var plate = frozen.pixels
        var missing = gate

        // Fill it from other frames: line each up on the background (the phone drifts), then take, pixel
        // by pixel, the frame with the median brightness. The kicker and the ball cover any one spot in
        // only a few frames, so the median is the background, with no need to know where they were.
        let small = frozen.downscaled(by: 4)
        let frozenLuma = frozen.luma()
        let step = max(1.0 / 60, duration / 20)
        var others: [(picture: Picture, shift: (x: Int, y: Int), person: PersonBox?, ball: (x: Double, y: Double, r: Double)?)] = []
        var t = step / 2
        while t < duration - 0.01 {
            try Task.checkCancellation()
            if abs(t - time) > 0.25, let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 60_000)).image,
               let picture = Picture(image, width: width, height: height) {
                let coarse = align(picture.downscaled(by: 4), to: small, skip: { x, y in gate[min(height - 1, y * 4) * width + min(width - 1, x * 4)] })
                // Then to the pixel: a few pixels off, tree and net texture would read as the kicker.
                let shift = refine(picture.luma(), to: frozenLuma, width: width, height: height, from: (coarse.x * 4, coarse.y * 4), skip: gate)
                let flying = ball.sample(at: t).flatMap { sample in sample.boxSize.map { size in
                    (x: Double(sample.center.x) * Double(width), y: Double(sample.center.y) * Double(height),
                     r: max(Double(size.width) * Double(width), Double(size.height) * Double(height)) * 0.9 + 0.01 * Double(width))
                } }
                others.append((picture, shift, ball.person(at: t), flying))
            }
            t += step
        }
        var lumas = [Int](repeating: 0, count: others.count), owners = [Int](repeating: 0, count: others.count)
        for y in 0..<height {
            for x in 0..<width where missing[y * width + x] {
                var count = 0
                for (k, other) in others.enumerated() {
                    let sx = x + other.shift.x, sy = y + other.shift.y
                    guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                    // Leave out where that frame's tracked kicker or ball stood.
                    let u = (Double(sx) + 0.5) / Double(width), v = (Double(sy) + 0.5) / Double(height)
                    if let p = other.person, abs(u - p.x) < p.width * 0.65 + 0.03, abs(v - p.y) < p.height * 0.58 + 0.03 { continue }
                    if let b = other.ball, abs(Double(sx) - b.x) < b.r, abs(Double(sy) - b.y) < b.r { continue }
                    let j = (sy * width + sx) * 4
                    lumas[count] = Int(other.picture.pixels[j + 2]) * 77 + Int(other.picture.pixels[j + 1]) * 150 + Int(other.picture.pixels[j]) * 29
                    owners[count] = k; count += 1
                }
                guard count >= 2 else { continue }
                // The median by brightness: sort the few candidates in place.
                for a in 1..<count {
                    var b = a
                    while b > 0, lumas[b - 1] > lumas[b] { lumas.swapAt(b - 1, b); owners.swapAt(b - 1, b); b -= 1 }
                }
                let other = others[owners[count / 2]]
                let j = ((y + other.shift.y) * width + x + other.shift.x) * 4, i = (y * width + x) * 4
                plate[i] = other.picture.pixels[j]; plate[i + 1] = other.picture.pixels[j + 1]; plate[i + 2] = other.picture.pixels[j + 2]
                missing[y * width + x] = false
            }
        }
        let fromFrames = zip(gate, missing).map { $0 && !$1 }
        // Anything never seen (the kicker stood there in every frame): blend the nearest background in
        // from left, right, above and below. Only a sliver of it shows, beside him, mid-swing.
        let unseen = missing
        func fill(along rows: Bool) -> [Double] {
            var out = [Double](repeating: -1, count: width * height * 3)
            let lines = rows ? height : width, length = rows ? width : height
            for line in 0..<lines {
                func index(_ k: Int) -> Int { rows ? line * width + k : k * width + line }
                var k = 0
                while k < length {
                    guard unseen[index(k)] else { k += 1; continue }
                    var end = k
                    while end < length, unseen[index(end)] { end += 1 }
                    let before = k > 0 ? index(k - 1) : nil, after = end < length ? index(end) : nil
                    for m in k..<end {
                        let f: Double = after == nil ? 0 : before == nil ? 1 : Double(m - k + 1) / Double(end - k + 1)
                        for c in 0..<3 {
                            let first: Int? = before ?? after, last: Int? = after ?? before
                            let a: Double = first.map { Double(plate[$0 * 4 + c]) } ?? 0
                            let b: Double = last.map { Double(plate[$0 * 4 + c]) } ?? a
                            out[index(m) * 3 + c] = a + (b - a) * f
                        }
                    }
                    k = end
                }
            }
            return out
        }
        if unseen.contains(true) {
            let across = fill(along: true), down = fill(along: false)
            for i in 0..<(width * height) where unseen[i] {
                for c in 0..<3 {
                    let blended: Double = (across[i * 3 + c] + down[i * 3 + c]) / 2
                    plate[i * 4 + c] = UInt8(min(255, max(0, blended)))
                }
            }
            // A flat blend reads as a pale patch against trees and netting, so keep their texture: copy it
            // across from the nearer side, mirrored at the edge, and use the blend only for its tone.
            for y in 0..<height {
                var x = 0
                while x < width {
                    guard unseen[y * width + x] else { x += 1; continue }
                    var end = x
                    while end < width, unseen[y * width + end] { end += 1 }
                    for k in x..<end {
                        let fromLeft = k - x < end - k
                        let mirror = fromLeft ? x - 1 - (k - x) : end + (end - 1 - k)
                        guard mirror >= 0, mirror < width, !unseen[y * width + mirror] else { continue }
                        let i = (y * width + k) * 4, j = (y * width + mirror) * 4
                        for c in 0..<3 {
                            let texture: Double = Double(plate[j + c]), tone: Double = Double(plate[i + c])
                            plate[i + c] = UInt8(min(255, max(0, texture * 0.8 + tone * 0.2)))
                        }
                    }
                    x = end
                }
            }
        }
        // His outline: Vision's mask, plus whatever near it differs from the clean background (bare legs,
        // a blurred kicking foot), so the cut-out stays whole where Vision is faint.
        let nearBody = seenByVision ? dilate(vision.map { $0 > 0.3 }, width: width, height: height, radius: max(8, width / 10)) : region
        var matte = vision
        for i in 0..<matte.count where fromFrames[i] && nearBody[i] && (region[i] || box == nil) {
            let j = i * 4
            let b = abs(Int(frozen.pixels[j]) - Int(plate[j])), g = abs(Int(frozen.pixels[j + 1]) - Int(plate[j + 1]))
            let r = abs(Int(frozen.pixels[j + 2]) - Int(plate[j + 2]))
            let k = min(1, max(0, (Float(max(b, g, r)) - 26) / 26))
            matte[i] = max(matte[i], k * k * (3 - 2 * k))
        }
        // Without Vision, a spot in his box that no other frame ever showed clear is him: he stood there
        // in every frame.
        if !seenByVision { for i in 0..<matte.count where unseen[i] && region[i] { matte[i] = 1 } }
        // A person is one solid shape: close small gaps, like a shirt as dark as the trees behind it.
        let solid = matte.map { $0 > 0.5 }
        let gap = max(4, width / 45)
        let closed = dilate(dilate(solid, width: width, height: height, radius: gap).map { !$0 }, width: width, height: height, radius: gap).map { !$0 }
        for i in 0..<matte.count where closed[i] && (region[i] || box == nil) { matte[i] = 1 }
        matte = soften(matte, width: width, height: height)
        guard matte.contains(where: { $0 > 0.5 }) else { return nil }
        for i in 0..<(width * height) { plate[i * 4 + 3] = UInt8(min(255, max(0, max(matte[i], ballCover[i]) * 255))) }
        return ShotArcLayers(bytes: plate, width: width, height: height, time: time, usedVision: seenByVision)
    }

    // MARK: Pieces

    /// BGRA pixels at a fixed size.
    private struct Picture {
        var pixels: [UInt8]
        var width: Int, height: Int

        init?(_ image: CGImage, width: Int, height: Int) {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            pixels = bytes; self.width = width; self.height = height
        }

        init(luma: [UInt8], width: Int, height: Int) {
            pixels = luma; self.width = width; self.height = height
        }

        /// Brightness of every pixel.
        func luma() -> [UInt8] {
            var out = [UInt8](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                out[i] = UInt8((Int(pixels[i * 4 + 2]) * 77 + Int(pixels[i * 4 + 1]) * 150 + Int(pixels[i * 4]) * 29) >> 8)
            }
            return out
        }

        /// Brightness, averaged over `factor` × `factor` blocks.
        func downscaled(by factor: Int) -> Picture {
            let w = max(1, width / factor), h = max(1, height / factor)
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var sum = 0
                    for dy in 0..<factor {
                        let row = min(height - 1, y * factor + dy) * width
                        for dx in 0..<factor {
                            let i = (row + min(width - 1, x * factor + dx)) * 4
                            sum += (Int(pixels[i + 2]) * 77 + Int(pixels[i + 1]) * 150 + Int(pixels[i]) * 29) >> 8
                        }
                    }
                    out[y * w + x] = UInt8(sum / (factor * factor))
                }
            }
            return Picture(luma: out, width: w, height: h)
        }
    }

    /// The whole-picture shift (in downscaled pixels) that best lines `other` up on `reference`.
    private static func align(_ other: Picture, to reference: Picture, skip: (Int, Int) -> Bool) -> (x: Int, y: Int) {
        let w = reference.width, h = reference.height
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { mask[y * w + x] = !skip(x, y) } }
        func cost(_ sx: Int, _ sy: Int, step: Int) -> Double {
            var sum = 0, count = 0
            var y = 4
            while y < h - 4 {
                var x = 4
                while x < w - 4 {
                    let ox = x + sx, oy = y + sy
                    if mask[y * w + x], ox >= 0, ox < w, oy >= 0, oy < h {
                        sum += abs(Int(reference.pixels[y * w + x]) - Int(other.pixels[oy * w + ox])); count += 1
                    }
                    x += step
                }
                y += step
            }
            return count > 50 ? Double(sum) / Double(count) : .infinity
        }
        var best = (x: 0, y: 0, cost: cost(0, 0, step: 2))
        for sy in stride(from: -10, through: 10, by: 2) {
            for sx in stride(from: -10, through: 10, by: 2) {
                let c = cost(sx, sy, step: 2)
                if c < best.cost { best = (sx, sy, c) }
            }
        }
        // Then every pixel, one step around the best coarse shift.
        let coarse = best
        best = (coarse.x, coarse.y, cost(coarse.x, coarse.y, step: 1))
        for sy in (coarse.y - 1)...(coarse.y + 1) {
            for sx in (coarse.x - 1)...(coarse.x + 1) {
                let c = cost(sx, sy, step: 1)
                if c < best.cost { best = (sx, sy, c) }
            }
        }
        return (best.x, best.y)
    }

    /// The full-resolution shift, within 4 pixels of `start`, that best lines `other` up on `reference`
    /// away from the `skip` area. Sampled on a sparse grid; that is plenty for one whole-picture shift.
    private static func refine(_ other: [UInt8], to reference: [UInt8], width: Int, height: Int,
                               from start: (x: Int, y: Int), skip: [Bool]) -> (x: Int, y: Int) {
        var best = (x: start.x, y: start.y, cost: Double.infinity)
        for sy in (start.y - 4)...(start.y + 4) {
            for sx in (start.x - 4)...(start.x + 4) {
                var sum = 0, count = 0
                var y = 12
                while y < height - 12 {
                    var x = 12
                    while x < width - 12 {
                        let ox = x + sx, oy = y + sy
                        if !skip[y * width + x], ox >= 0, ox < width, oy >= 0, oy < height {
                            sum += abs(Int(reference[y * width + x]) - Int(other[oy * width + ox])); count += 1
                        }
                        x += 6
                    }
                    y += 6
                }
                let cost = count > 200 ? Double(sum) / Double(count) : .infinity
                if cost < best.cost { best = (sx, sy, cost) }
            }
        }
        return (best.x, best.y)
    }

    /// A 3 × 3 average, to take the stair-steps off an outline.
    private static func soften(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard width > 2, height > 2 else { return values }
        var out = values
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: Float = 0
                for dy in -1...1 { for dx in -1...1 { sum += values[(y + dy) * width + x + dx] } }
                out[y * width + x] = sum / 9
            }
        }
        return out
    }

    private static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            var last = -radius - 1
            for x in 0..<width { if mask[y * width + x] { last = x }; if x - last <= radius { horizontal[y * width + x] = true } }
            last = width + radius + 1
            for x in stride(from: width - 1, through: 0, by: -1) { if mask[y * width + x] { last = x }; if last - x <= radius { horizontal[y * width + x] = true } }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for x in 0..<width {
            var last = -radius - 1
            for y in 0..<height { if horizontal[y * width + x] { last = y }; if y - last <= radius { out[y * width + x] = true } }
            last = height + radius + 1
            for y in stride(from: height - 1, through: 0, by: -1) { if horizontal[y * width + x] { last = y }; if last - y <= radius { out[y * width + x] = true } }
        }
        return out
    }

    /// Vision's person mask, 0 – 1, at the layer size. It runs on a crop around the kicker, so a
    /// kicker far from the phone still fills enough of Vision's input to be found.
    private static func personMask(_ image: CGImage, around box: PersonBox?, width: Int, height: Int) -> [Float]? {
        let iw = Double(image.width), ih = Double(image.height)
        var crop = CGRect(x: 0, y: 0, width: iw, height: ih)
        if let box {
            let w = box.width * 1.6 + 0.06, h = box.height * 1.35 + 0.06
            crop = CGRect(x: (box.x - w / 2) * iw, y: (box.y - h / 2) * ih, width: w * iw, height: h * ih).integral
                .intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        }
        guard crop.width > 8, crop.height > 8, let piece = image.cropping(to: crop) else { return nil }
        var mask: CVPixelBuffer?
        for quality in [VNGeneratePersonSegmentationRequest.QualityLevel.accurate, .balanced] where mask == nil {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = quality
            request.revision = VNGeneratePersonSegmentationRequestRevision1
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            guard (try? VNImageRequestHandler(cgImage: piece, orientation: .up, options: [:]).perform([request])) != nil,
                  let result = request.results?.first?.pixelBuffer, hasPerson(result) else { continue }
            mask = result
        }
        guard let mask else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self), mw > 1, mh > 1 else { return nil }
        var out = [Float](repeating: 0, count: width * height)
        let sx = iw / Double(width), sy = ih / Double(height)
        for y in 0..<height {
            let py = (Double(y) + 0.5) * sy
            guard py >= crop.minY, py < crop.maxY else { continue }
            let fy = (py - crop.minY) / crop.height * Double(mh) - 0.5
            let y0 = min(mh - 1, max(0, Int(fy))), y1 = min(mh - 1, y0 + 1), ty = Float(min(1, max(0, fy - Double(y0))))
            for x in 0..<width {
                let px = (Double(x) + 0.5) * sx
                guard px >= crop.minX, px < crop.maxX else { continue }
                let fx = (px - crop.minX) / crop.width * Double(mw) - 0.5
                let x0 = min(mw - 1, max(0, Int(fx))), x1 = min(mw - 1, x0 + 1), tx = Float(min(1, max(0, fx - Double(x0))))
                let a = Float(base[y0 * row + x0]) * (1 - tx) + Float(base[y0 * row + x1]) * tx
                let b = Float(base[y1 * row + x0]) * (1 - tx) + Float(base[y1 * row + x1]) * tx
                let v = (a * (1 - ty) + b * ty) / 255
                out[y * width + x] = min(1, max(0, (v - 0.3) / 0.4))
            }
        }
        return out
    }

    /// A mask image at the layer size, on the same 0 – 1 scale as Vision's.
    private static func resampled(_ mask: CGImage, width: Int, height: Int) -> [Float]? {
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = gray.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? gray.map { min(1, max(0, (Float($0) / 255 - 0.3) / 0.4)) } : nil
    }

    private static func hasPerson(_ mask: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let row = CVPixelBufferGetBytesPerRow(mask)
        for y in 0..<CVPixelBufferGetHeight(mask) {
            for x in 0..<CVPixelBufferGetWidth(mask) where base[y * row + x] > 128 { return true }
        }
        return false
    }
}
