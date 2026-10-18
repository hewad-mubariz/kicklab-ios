import SwiftUI

/// Every camera move as a card, grouped by family. Each card plays a small diagram of the move
/// over a frame of this shot, using this shot's real ball flight.
struct ShotMoveCarousel: View {
    /// The move being changed, when swapping a block's move instead of adding one.
    var replacing: ShotCameraMove?
    let image: CGImage?
    let flight: [CGPoint]
    let hasBall: Bool
    let hasKicker: Bool
    let onPick: (ShotCameraMove) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var family: ShotCameraMove.Family?
    @State private var kicks: [ShotCameraMove: Int] = [:]
    @Namespace private var pill

    private var moves: [ShotCameraMove] { ShotCameraMove.allCases.filter { family == nil || $0.family == family } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            familyBar.padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(moves.enumerated()), id: \.element) { index, move in
                        card(move).sessionEntrance(true, order: min(index, 5), offset: 10, scale: 0.92)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .id(family?.rawValue ?? "all")
            .transition(.opacity)
        }
        .sensoryFeedback(.selection, trigger: family)
    }

    private var familyBar: some View {
        HStack(spacing: 6) {
            chip(nil, title: "All")
            ForEach(ShotCameraMove.Family.allCases) { chip($0, title: $0.rawValue) }
        }
    }

    private func chip(_ value: ShotCameraMove.Family?, title: String) -> some View {
        let selected = family == value
        return Button {
            withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { family = value }
        } label: {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.75))
                .padding(.horizontal, 11).frame(height: 28)
                .background {
                    if selected { Capsule().fill(.white).matchedGeometryEffect(id: "family", in: pill) }
                    else { Capsule().fill(.white.opacity(0.06)) }
                }
        }
        .buttonStyle(SessionPressStyle(scale: 0.93))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("shot-camera-family-\(title.lowercased())")
    }

    private func card(_ move: ShotCameraMove) -> some View {
        let unavailable = (move.needsBall && !hasBall) || (move.needsPerson && !hasKicker)
        let current = replacing == move
        return Button {
            kicks[move, default: 0] += 1
            onPick(move)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ShotMoveSketch(move: move, image: image, flight: flight)
                    .frame(width: 88, height: 112)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(current ? move.tint : .white.opacity(0.1), lineWidth: current ? 2 : 0.5)
                    }
                    .overlay(alignment: .topLeading) {
                        Circle().fill(move.tint).frame(width: 7, height: 7).padding(8)
                    }
                    .sessionKick(kicks[move, default: 0], amount: 0.07)
                Text(move.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(current ? move.tint : .white.opacity(0.9))
                    .frame(width: 88, alignment: .leading)
            }
            .opacity(unavailable ? 0.4 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.93))
        .disabled(unavailable)
        .accessibilityLabel(move.title + (unavailable ? ", needs " + (move.needsPerson ? "the kicker in view" : "a tracked ball") : ""))
        .accessibilityHint(move.detail)
        .accessibilityIdentifier("shot-camera-move-\(move.rawValue)")
    }
}

/// A looping diagram of one camera move over a still of the shot: where the camera looks, how it
/// zooms, turns, splits or changes time, following the real ball flight.
struct ShotMoveSketch: View {
    let move: ShotCameraMove
    let image: CGImage?
    let flight: [CGPoint]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let loop = 2.6
    private static let lime = Color(red: 0.8, green: 1, blue: 0.43)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let u = reduceMotion ? 0.55 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.loop) / Self.loop
            Canvas { gc, size in draw(in: &gc, size: size, u: u) }
        }
        .background(Color(red: 0.05, green: 0.08, blue: 0.06))
        .accessibilityHidden(true)
    }

    // MARK: Story

    /// The ball rests, flies, then rests in the goal: 0 – 1 along the real flight.
    private func flightProgress(_ u: Double) -> Double {
        let t = min(1, max(0, (u - 0.18) / 0.55))
        return 1 - pow(1 - t, 2.2)
    }
    private func ball(_ p: Double) -> CGPoint {
        guard flight.count > 1 else { return CGPoint(x: 0.55 + 0.1 * p, y: 0.75 - 0.4 * p) }
        let f = min(Double(flight.count - 1), max(0, p * Double(flight.count - 1))), i = min(flight.count - 2, Int(f)), k = f - Double(i)
        let a = flight[i], b = flight[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }
    private func pulse(_ u: Double, at: Double, width: Double) -> Double {
        let d = abs(u - at) / width
        return d < 1 ? (1 + cos(.pi * d)) / 2 : 0
    }

    // MARK: Drawing

    /// Picture coordinates (0 – 1) to card points, as the still is aspect-filled.
    private func mapper(_ size: CGSize) -> (CGPoint) -> CGPoint {
        let aspect = image.map { Double($0.width) / Double(max(1, $0.height)) } ?? 9.0 / 16
        let cardAspect = Double(size.width / size.height)
        let w = aspect > cardAspect ? Double(size.height) * aspect : Double(size.width)
        let h = aspect > cardAspect ? Double(size.height) : Double(size.width) / aspect
        let ox = (Double(size.width) - w) / 2, oy = (Double(size.height) - h) / 2
        return { CGPoint(x: ox + $0.x * w, y: oy + $0.y * h) }
    }
    private func pictureRect(_ size: CGSize) -> CGRect {
        let map = mapper(size)
        let a = map(.zero), b = map(CGPoint(x: 1, y: 1))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private func drawPicture(_ gc: inout GraphicsContext, _ size: CGSize, zoom: Double = 1, center: CGPoint? = nil,
                             angle: Double = 0, dim: Double = 0) {
        guard let image else { return }
        let rect = pictureRect(size)
        var copy = gc
        let c = center.map(mapper(size)) ?? CGPoint(x: size.width / 2, y: size.height / 2)
        copy.translateBy(x: size.width / 2, y: size.height / 2)
        copy.rotate(by: .radians(angle))
        copy.scaleBy(x: zoom, y: zoom)
        copy.translateBy(x: -c.x, y: -c.y)
        copy.draw(Image(decorative: image, scale: 1), in: rect)
        if dim > 0 { gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(dim))) }
    }

    private func drawBall(_ gc: inout GraphicsContext, at p: CGPoint, radius: Double = 4) {
        let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        gc.fill(Path(ellipseIn: r), with: .color(.white))
        gc.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.5)), lineWidth: 0.8)
    }

    /// The camera's view: everything outside is dimmed and the frame is outlined.
    private func drawViewport(_ gc: inout GraphicsContext, _ size: CGSize, center: CGPoint, zoom: Double, angle: Double = 0) {
        let c = mapper(size)(center)
        let w = size.width / zoom, h = size.height / zoom
        var frame = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 5)
        frame = frame.applying(CGAffineTransform(rotationAngle: angle)).applying(CGAffineTransform(translationX: c.x, y: c.y))
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addPath(frame)
        gc.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        gc.stroke(frame, with: .color(Self.lime), lineWidth: 1.6)
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, u: Double) {
        let map = mapper(size)
        let p = flightProgress(u)
        let b = ball(p), contact = ball(0)
        switch move {
        case .follow:
            drawPicture(&gc, size)
            drawViewport(&gc, size, center: ball(max(0, p - 0.05)), zoom: 1.7 + 0.6 * p)
            drawBall(&gc, at: map(b))
        case .chase:
            drawPicture(&gc, size)
            drawViewport(&gc, size, center: b, zoom: 1.3 + 2.2 * p)
            drawBall(&gc, at: map(b), radius: 4 - 1.5 * p)
        case .broadcast:
            drawPicture(&gc, size)
            let lag = max(0, p - 0.14) + 0.04 * sin(p * .pi * 3) * p
            drawViewport(&gc, size, center: ball(min(1, lag)), zoom: 1.4 + 0.8 * p)
            drawBall(&gc, at: map(b))
        case .handoff:
            drawPicture(&gc, size)
            let kicker = CGPoint(x: contact.x - 0.16, y: contact.y - 0.2)
            let w = min(1, max(0, (u - 0.2) / 0.1))
            let center = CGPoint(x: kicker.x + (b.x - kicker.x) * w, y: kicker.y + (b.y - kicker.y) * w)
            drawViewport(&gc, size, center: center, zoom: 1.6 + 0.6 * w)
            drawBall(&gc, at: map(b))
        case .split, .duo:
            let open = move == .split ? 1 : min(1, max(0, (u - 0.2) / 0.12))
            let divider = size.height * (1 - 0.5 * open)
            var top = gc
            top.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: divider)))
            if move == .duo { drawPicture(&top, size, zoom: 1 + 0.6 * open, center: CGPoint(x: contact.x - 0.15, y: contact.y - 0.2)) }
            else { drawPicture(&top, size) }
            var bottom = gc
            bottom.clip(to: Path(CGRect(x: 0, y: divider, width: size.width, height: size.height - divider)))
            if open > 0 {
                bottom.translateBy(x: 0, y: (divider - size.height * 0.5) * 0.5)
                drawPicture(&bottom, size, zoom: 2.2, center: b)
            }
            gc.fill(Path(CGRect(x: 0, y: divider - 1, width: size.width, height: 2)), with: .color(Self.lime))
            drawBall(&gc, at: map(b))
        case .impact:
            let punch = pulse(u, at: 0.22, width: 0.16)
            drawPicture(&gc, size, zoom: 1 + 1.1 * punch, center: contact)
            if punch > 0.85 { gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity((punch - 0.85) * 2.5))) }
        case .tilt:
            let k = pulse(u, at: 0.22, width: 0.2)
            drawPicture(&gc, size, zoom: 1.1, angle: -0.14 * k)
        case .recoil:
            let tau = max(0, u - 0.2)
            let swing = u < 0.2 ? 0 : -0.18 * exp(-tau / 0.1) * cos(2 * .pi * tau / 0.16)
            let shake = u < 0.2 ? 0 : 4 * exp(-tau / 0.06) * sin(tau * 160)
            var copy = gc
            copy.translateBy(x: shake, y: shake * 0.6)
            drawPicture(&copy, size, zoom: 1.15, angle: swing)
        case .ripple:
            drawPicture(&gc, size)
            let c = map(contact)
            for e in 0..<2 {
                let age = u - 0.22 - Double(e) * 0.06
                guard age > 0, age < 0.5 else { continue }
                let r = 6 + age * 220
                gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(0.7 * (1 - age / 0.5))), lineWidth: 2.5 - age * 3)
            }
        case .warp:
            drawPicture(&gc, size, zoom: 1 + 0.15 * p)
            let c = map(b), k = max(0, 1 - abs(u - 0.3) / 0.15)
            for i in 0..<18 where k > 0 {
                let a = Double(i) / 18 * 2 * .pi
                var line = Path()
                line.move(to: CGPoint(x: c.x + cos(a) * 14, y: c.y + sin(a) * 14))
                line.addLine(to: CGPoint(x: c.x + cos(a) * (14 + 60 * k), y: c.y + sin(a) * (14 + 60 * k)))
                gc.stroke(line, with: .color(.white.opacity(0.5 * k)), lineWidth: 1)
            }
            drawBall(&gc, at: c)
        case .ramp:
            // Time bends: the flight crawls through the middle.
            let slowP = u < 0.18 ? 0 : u < 0.78 ? 0.5 * (1 - cos(.pi * (u - 0.18) / 0.6)) : 1
            drawPicture(&gc, size, zoom: 1 + 0.3 * sin(.pi * slowP), center: contact)
            drawBall(&gc, at: map(ball(slowP)))
            if u > 0.25 && u < 0.72 { label(&gc, "×0.25", at: CGPoint(x: size.width - 8, y: 10), trailing: true) }
        case .freeze:
            drawPicture(&gc, size, dim: u > 0.18 && u < 0.6 ? 0.25 : 0)
            let hold = u > 0.18 && u < 0.6
            let drawn = hold ? (u - 0.18) / 0.42 : u >= 0.6 ? 1 : 0
            var path = Path()
            for i in 0...30 where Double(i) / 30 <= drawn {
                let q = map(ball(Double(i) / 30))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            gc.stroke(path, with: .color(Self.lime), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let flightP = u < 0.6 ? 0 : min(1, (u - 0.6) / 0.3)
            drawBall(&gc, at: map(ball(flightP)))
        case .arc:
            // Frozen on contact, the backdrop slides behind the kicker as the camera swings round him.
            let hold = u > 0.12 && u < 0.88
            let k = hold ? sin(2 * .pi * (u - 0.12) / 0.76) : 0
            var back = gc
            back.translateBy(x: size.width * 0.1 * k, y: 0)
            drawPicture(&back, size, zoom: 1.08)
            let c = map(contact)
            let orbit = Path(ellipseIn: CGRect(x: c.x - 28, y: c.y - 7, width: 56, height: 14))
            gc.stroke(orbit, with: .color(Self.lime.opacity(hold ? 0.9 : 0.35)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            let around = Double.pi / 2 + 0.9 * k
            gc.fill(Path(ellipseIn: CGRect(x: c.x + 28 * cos(around) - 3, y: c.y + 7 * sin(around) - 3, width: 6, height: 6)), with: .color(Self.lime))
            drawBall(&gc, at: c)
            if hold { label(&gc, "❚❚", at: CGPoint(x: 8, y: 10)) }
        case .replay:
            let phase: (p: Double, text: String?) = u < 0.4 ? (min(1, u / 0.35), nil)
                : u < 0.52 ? (1 - (u - 0.4) / 0.12, "◀◀") : (min(1, (u - 0.52) / 0.45), "REPLAY")
            let zoom = u > 0.52 ? 1.6 + 0.6 * phase.p : 1
            drawPicture(&gc, size, zoom: zoom, center: u > 0.52 ? ball(phase.p) : nil,
                        dim: u >= 0.4 && u < 0.52 ? 0.2 : 0)
            if u <= 0.52 { drawBall(&gc, at: map(ball(phase.p))) } else { drawBall(&gc, at: CGPoint(x: size.width / 2, y: size.height / 2), radius: 5) }
            if let text = phase.text { label(&gc, text, at: CGPoint(x: 8, y: 10)) }
        case .lens:
            drawPicture(&gc, size)
            let center = CGPoint(x: size.width * 0.3, y: size.height * 0.2), radius = size.width * 0.24
            var lens = gc
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            lens.clip(to: circle)
            lens.translateBy(x: center.x - size.width / 2, y: center.y - size.height / 2)
            drawPicture(&lens, size, zoom: 2.4 + 1.6 * p, center: b)
            gc.stroke(circle, with: .color(Self.lime), lineWidth: 1.5)
            let target = map(b)
            var leader = Path(); leader.move(to: center); leader.addLine(to: target)
            gc.stroke(leader, with: .color(Self.lime.opacity(0.8)), lineWidth: 0.8)
            drawBall(&gc, at: target, radius: 3)
        case .spotlight:
            drawPicture(&gc, size)
            let c = map(b)
            var dark = Path(CGRect(origin: .zero, size: size))
            dark.addEllipse(in: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36))
            gc.fill(dark, with: .color(.black.opacity(0.62)), style: FillStyle(eoFill: true))
            drawBall(&gc, at: c)
        case .focus:
            var soft = gc
            soft.addFilter(.blur(radius: 3.5))
            drawPicture(&soft, size)
            let c = map(u < 0.2 ? contact : b)
            var sharp = gc
            sharp.clip(to: Path(ellipseIn: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40)))
            drawPicture(&sharp, size)
            drawBall(&gc, at: c)
        case .strobe:
            drawPicture(&gc, size, dim: 0.1)
            for i in 0..<8 {
                let q = Double(i) / 8
                guard q < p - 0.02 else { break }
                drawBall(&gc, at: map(ball(q)), radius: 3.6 - q * 1.2)
            }
            drawBall(&gc, at: map(b))
        case .lock:
            drawPicture(&gc, size)
            let c = map(b), lock = min(1, max(0, (u - 0.18) / 0.12))
            let s = 9 + 22 * (1 - lock)
            for k in 0..<4 {
                let sx: CGFloat = k & 1 == 0 ? -1 : 1, sy: CGFloat = k & 2 == 0 ? -1 : 1
                var bracket = Path()
                bracket.move(to: CGPoint(x: c.x + sx * s, y: c.y + sy * (s - 6)))
                bracket.addLine(to: CGPoint(x: c.x + sx * s, y: c.y + sy * s))
                bracket.addLine(to: CGPoint(x: c.x + sx * (s - 6), y: c.y + sy * s))
                gc.stroke(bracket, with: .color(u < 0.18 ? .white.opacity(0.6) : Self.lime), lineWidth: 1.5)
            }
            drawBall(&gc, at: c)
            if u > 0.18 { label(&gc, String(format: "%.2f s", min(0.9, (u - 0.18) * 1.6)), at: CGPoint(x: c.x + s + 4, y: c.y - 5)) }
        }
    }

    private func label(_ gc: inout GraphicsContext, _ text: String, at point: CGPoint, trailing: Bool = false) {
        gc.draw(Text(text).font(.system(size: 9, weight: .heavy)).foregroundStyle(Self.lime),
                at: point, anchor: trailing ? .topTrailing : .topLeading)
    }
}
