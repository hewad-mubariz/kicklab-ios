import SwiftUI

/// Ways to show a shot under the replay, in the spirit of the juggling motion styles: simple,
/// graphical, the whole shot visible at once (what is still to come drawn faintly), lit up as
/// the replay plays. Everything is read from the shot's own track and drawn from the playhead,
/// so pausing, scrubbing and replaying are deterministic. Nothing claims a physical speed.
nonisolated enum ShotGraphStyle: String, CaseIterable, Identifiable {
    case comet, ballMotion, kickPulse, rainbow, fireworks, tape
    var id: String { rawValue }

    var title: String {
        switch self {
        case .comet: "Comet"
        case .ballMotion: "Ball Motion"
        case .kickPulse: "Kick Pulse"
        case .rainbow: "Rainbow"
        case .fireworks: "Fireworks"
        case .tape: "Tape Measure"
        }
    }

    var subtitle: String {
        switch self {
        case .comet: "Your shot across the sky"
        case .ballMotion: "Height in the picture"
        case .kickPulse: "Speed in the picture"
        case .rainbow: "Your shot in colour"
        case .fireworks: "Farther shots, bigger bursts"
        case .tape: "Roll distance · experimental"
        }
    }

    var measure: String {
        switch self {
        case .comet, .kickPulse, .rainbow: "IN FRAME"
        case .ballMotion: "RELATIVE"
        case .fireworks: "× FARTHER"
        case .tape: "METRES"
        }
    }

    var caption: String {
        switch self {
        case .comet: "A comet in your effect's colours"
        case .ballMotion: "The ball rests, then launches"
        case .kickPulse: "The kick as a heartbeat"
        case .rainbow: "A rainbow follows the ball"
        case .fireworks: "One firework for every shot"
        case .tape: "A tape unrolls with your roll"
        }
    }

    /// Only rolls recorded in the app have a distance to measure.
    static func available(hasDistance: Bool) -> [ShotGraphStyle] {
        allCases.filter { $0 != .tape || hasDistance }
    }
}

struct ShotGraph: View {
    let style: ShotGraphStyle
    let flight: ShotFlight
    let time: Double
    /// The chosen trail's colours, ball outward.
    var palette: [Color] = ShotTrailStyle.limeRibbon.palette
    var distance: BallDistanceTimeline? = nil

    private let gold = Color(red: 1, green: 0.8, blue: 0.28)
    private let ivory = Color(red: 0.99, green: 0.98, blue: 0.88)

    var body: some View {
        Canvas { context, size in
            switch style {
            case .comet: comet(&context, size)
            case .ballMotion: ballMotion(&context, size)
            case .kickPulse: kickPulse(&context, size)
            case .rainbow: rainbow(&context, size)
            case .fireworks: fireworks(&context, size)
            case .tape: tape(&context, size)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Shared

    private var flown: Int {
        switch flight.phase(at: time) {
        case .waiting: -1
        case .flying: flight.flownIndex(at: time)
        case .done: flight.points.count - 1
        }
    }

    private var head: Color { palette.first ?? .white }
    private var body1: Color { palette.count > 1 ? palette[1] : head }
    private var tail: Color { palette.last ?? head }

    /// A stable pseudo-random number in 0..<1.
    private func noise(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    /// Time runs left to right across the box; height is where the ball was in the picture, so
    /// a shot rising up the screen climbs to the right. A nearly flat shot stays near the middle.
    private func sideView(_ rect: CGRect) -> (Int) -> CGPoint {
        let ys: [Double] = flight.points.map { $0.y }
        let top = ys.min() ?? 0, span = max(0.0001, (ys.max() ?? 1) - top)
        let fill = CGFloat(min(1, span / 0.06))
        let last = CGFloat(max(1, flight.points.count - 1))
        return { index in
            let across: CGFloat = CGFloat(index) / last
            let down: CGFloat = CGFloat((flight.points[index].y - top) / span) - 0.5
            return CGPoint(x: rect.minX + rect.width * across, y: rect.midY + down * rect.height * fill)
        }
    }

    /// The run-up second, the flight and a beat after, for the time-based graphs.
    private var timeline: [ShotFlight.Point] { flight.lead + flight.points }
    private var window: (start: Double, end: Double) {
        (min(flight.lead.first?.time ?? flight.launch - 0.8, flight.launch - 0.3), flight.end + 0.5)
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func label(_ value: String, at point: CGPoint, in context: inout GraphicsContext, size: CGFloat,
                       weight: Font.Weight = .heavy, color: Color = .white, anchor: UnitPoint = .center,
                       design: Font.Design = .rounded) {
        context.draw(Text(value).font(.system(size: size, weight: weight, design: design)).monospacedDigit()
            .foregroundStyle(color), at: point, anchor: anchor)
    }

    /// A small rounded tag with bold text.
    private func pill(_ value: String, at point: CGPoint, in context: inout GraphicsContext, size: CGFloat,
                      fill: Color, ink: Color = .black, anchor: UnitPoint = .center) {
        let text = context.resolve(Text(value).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundStyle(ink))
        let measured = text.measure(in: CGSize(width: 400, height: 100))
        let width = measured.width + size, height = measured.height + size * 0.5
        let rect = CGRect(x: point.x - width * anchor.x, y: point.y - height * anchor.y, width: width, height: height)
        context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(fill))
        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func sphere(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, spin: Double = 0) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.white, ivory, Color(red: 0.62, green: 0.68, blue: 0.66)]),
            center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.3),
            startRadius: 0, endRadius: radius * 1.5))
        guard radius > 4 else { return }
        // Two panel seams turning with the ball.
        var seams = context
        seams.clip(to: Path(ellipseIn: rect))
        for k in 0..<2 {
            let angle = spin + Double(k) * .pi / 2
            let dx = CGFloat(cos(angle)) * radius, dy = CGFloat(sin(angle)) * radius
            var seam = Path()
            seam.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            seam.addQuadCurve(to: CGPoint(x: center.x + dx, y: center.y + dy),
                              control: CGPoint(x: center.x - dy * 0.5, y: center.y + dx * 0.5))
            seams.stroke(seam, with: .color(.black.opacity(0.35)), lineWidth: max(0.6, radius * 0.08))
        }
    }

    /// A small night sky, so stars and glow read over any video.
    private func backdrop(_ context: inout GraphicsContext, _ size: CGSize) {
        let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: min(14, size.height * 0.14))
        context.fill(shape, with: .linearGradient(
            Gradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.1).opacity(0.9), Color(red: 0.07, green: 0.04, blue: 0.16).opacity(0.9)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.clip(to: shape)
    }

    /// A dark screen with a faint grid, for the time-based graphs.
    private func monitor(_ context: inout GraphicsContext, _ size: CGSize, fine: Bool) {
        let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: min(14, size.height * 0.14))
        context.fill(shape, with: .color(Color(red: 0.02, green: 0.04, blue: 0.05).opacity(0.9)))
        context.clip(to: shape)
        let columns = fine ? 24 : 8, rows = fine ? 8 : 4
        var grid = Path()
        for column in 1..<columns {
            let x = size.width * CGFloat(column) / CGFloat(columns)
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for row in 1..<rows {
            let y = size.height * CGFloat(row) / CGFloat(rows)
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(body1.opacity(fine ? 0.07 : 0.06)), lineWidth: 0.5)
    }

    /// Splits a polyline at `now` into what has played and what is still to come.
    private func split(_ points: [(time: Double, at: CGPoint)], now: Double) -> (past: Path, future: Path, current: CGPoint?) {
        var past = Path(), future = Path()
        var current: CGPoint?
        for (index, point) in points.enumerated() {
            if point.time <= now {
                index == 0 || past.isEmpty ? past.move(to: point.at) : past.addLine(to: point.at)
                current = point.at
            } else {
                if future.isEmpty {
                    if index > 0, let previous = Optional(points[index - 1]), previous.time <= now {
                        // The point exactly at the playhead joins both halves.
                        let f = CGFloat((now - previous.time) / max(0.0001, point.time - previous.time))
                        let joint = CGPoint(x: previous.at.x + (point.at.x - previous.at.x) * f,
                                            y: previous.at.y + (point.at.y - previous.at.y) * f)
                        past.addLine(to: joint)
                        current = joint
                        future.move(to: joint)
                    } else {
                        future.move(to: point.at)
                    }
                }
                future.addLine(to: point.at)
            }
        }
        return (past, future, current)
    }

    private func glowStroke(_ context: inout GraphicsContext, _ path: Path, color: Color, width: CGFloat, blur: CGFloat) {
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: blur))
            glow.stroke(path, with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: width * 2.6, lineCap: .round, lineJoin: .round))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Comet: the shot as a comet across a night sky, in the effect's colours

    private func comet(_ context: inout GraphicsContext, _ size: CGSize) {
        backdrop(&context, size)
        // Stars twinkle behind everything.
        let count = Int(size.width * size.height / 240)
        for index in 0..<count {
            let point = CGPoint(x: noise(index, 1) * size.width, y: noise(index, 2) * size.height)
            let twinkle = 0.18 + 0.32 * (0.5 + 0.5 * sin(time * (1.4 + noise(index, 4) * 3) + Double(index)))
            context.fill(circle(point, 0.4 + noise(index, 3) * 0.8), with: .color(.white.opacity(twinkle)))
        }
        let pad = min(18, size.height * 0.16)
        let lane = CGRect(x: pad, y: pad, width: size.width - pad * 3.2, height: size.height - pad * 2)
        let map = sideView(lane)
        let points = flight.points.indices.map(map)
        var ahead = Path()
        ahead.addLines(points)
        context.stroke(ahead, with: .color(.white.opacity(0.13)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 5]))
        let kick = points[0]
        let scale = min(1, size.height / 110)

        if flown < 0 {
            // Waiting for the kick: the spot pulses.
            let pulse = 0.5 + 0.5 * sin(time * 5)
            context.stroke(circle(kick, (6 + 4 * pulse) * scale), with: .color(body1.opacity(0.4 + 0.4 * pulse)), lineWidth: 1.4)
            context.fill(circle(kick, 2.5 * scale), with: .color(head))
            return
        }
        let current = min(flown, points.count - 1)
        var lit = context
        lit.blendMode = .plusLighter
        let firstRadius = max(0.0005, flight.points[0].radius)
        // The tail: thick and hot at the ball, thin and cool where it came from.
        func headRadius(_ index: Int) -> CGFloat {
            (2.6 + 4.2 * min(1, CGFloat(flight.points[index].radius / firstRadius))) * scale
        }
        if current > 0 {
            let segments: [(path: Path, f: Double, width: CGFloat)] = (1...current).map { index in
                let f = Double(index) / Double(max(1, current))
                var segment = Path()
                segment.move(to: points[index - 1]); segment.addLine(to: points[index])
                return (segment, f, 0.6 + CGFloat(pow(f, 1.6)) * headRadius(index) * 1.7)
            }
            // One blurred layer for the whole glow, then the crisp tail on top.
            lit.drawLayer { glow in
                glow.addFilter(.blur(radius: 4 * scale))
                for segment in segments {
                    glow.stroke(segment.path, with: .color(body1.opacity(0.55 * segment.f)),
                                style: StrokeStyle(lineWidth: segment.width * 2.4, lineCap: .round))
                }
            }
            for segment in segments {
                let ink = segment.f > 0.66 ? head : segment.f > 0.33 ? body1 : tail
                lit.stroke(segment.path, with: .color(ink.opacity(0.35 + 0.65 * segment.f)),
                           style: StrokeStyle(lineWidth: segment.width, lineCap: .round))
            }
            // Sparks shed along the path drift and fade.
            for index in stride(from: 0, through: current, by: 2) {
                let age = time - flight.points[index].time
                guard age >= 0, age < 1 else { continue }
                for k in 0..<2 {
                    let angle: Double = noise(index, 10 + k) * 2 * .pi
                    let speed: CGFloat = CGFloat(10 + noise(index, 20 + k) * 16)
                    let reach: CGFloat = CGFloat(age) * speed * scale
                    let fall: CGFloat = CGFloat(age * age) * 10 * scale
                    let sparkX: CGFloat = points[index].x + CGFloat(cos(angle)) * reach
                    let sparkY: CGFloat = points[index].y + CGFloat(sin(angle)) * reach + fall
                    let twinkle = 0.6 + 0.4 * sin(time * 30 + Double(index * 3 + k))
                    let ink = [head, body1, tail][(index + k) % 3]
                    lit.fill(circle(CGPoint(x: sparkX, y: sparkY), CGFloat(0.6 + noise(index, 30 + k) * 1.1) * scale),
                             with: .color(ink.opacity((1 - age) * twinkle)))
                }
            }
        }
        // The kick flashes and calls out.
        let sinceKick = time - flight.launch
        if sinceKick >= 0 && sinceKick < 0.45 {
            let k = sinceKick / 0.45
            lit.stroke(circle(kick, CGFloat(4 + k * 38) * scale), with: .color(body1.opacity(1 - k)), lineWidth: 2 * scale)
            lit.fill(circle(kick, CGFloat(10 * (1 - k)) * scale), with: .color(.white.opacity(1 - k)))
            let pop = min(1, sinceKick / 0.12)
            label("KICK!", at: CGPoint(x: kick.x, y: kick.y - 14 * scale - CGFloat(k) * 8 * scale), in: &context,
                  size: CGFloat(8 + 4 * pop) * scale, color: head.opacity(1 - pow(k, 3)))
        }
        if flown < flight.points.count - 1 {
            let at = points[current]
            let r = headRadius(current)
            lit.drawLayer { glow in
                glow.addFilter(.blur(radius: 5 * scale))
                glow.fill(circle(at, r * 2.4), with: .color(body1.opacity(0.8)))
            }
            lit.fill(circle(at, r), with: .color(.white))
        } else {
            // Landed: a starburst, then the time in the air stays pinned to the end.
            let end = points[points.count - 1]
            let e = time - flight.end
            let open = min(1, e / 0.35)
            for ray in 0..<10 {
                let angle = Double(ray) / 10 * 2 * .pi + 0.3
                let from = CGFloat(3 + 3 * open) * scale, to = CGFloat(5 + 13 * open) * scale
                var line = Path()
                line.move(to: CGPoint(x: end.x + CGFloat(cos(angle)) * from, y: end.y + CGFloat(sin(angle)) * from))
                line.addLine(to: CGPoint(x: end.x + CGFloat(cos(angle)) * to, y: end.y + CGFloat(sin(angle)) * to))
                lit.stroke(line, with: .color(head.opacity(max(0.25, 1 - e / 0.9))), style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round))
            }
            lit.fill(circle(end, 3 * scale), with: .color(.white))
            let above = end.y > size.height * 0.4
            pill(String(format: "%.2f s", flight.airTime), at: CGPoint(x: min(end.x, size.width - 4), y: end.y + (above ? -14 : 14) * scale),
                 in: &context, size: 9 * scale, fill: body1, anchor: UnitPoint(x: end.x > size.width - 40 ? 1 : 0.5, y: above ? 1 : 0))
        }
    }

    // MARK: - Ball Motion: the juggling line graph, for one shot. The ball rests, then launches.

    private func ballMotion(_ context: inout GraphicsContext, _ size: CGSize) {
        monitor(&context, size, fine: false)
        let scale = min(1, size.height / 110)
        let pad = min(12, size.height * 0.12)
        let axis = 14 * scale
        let plot = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2 - axis)
        let samples = timeline
        let span = window
        let ys: [Double] = samples.map { $0.y }
        let top = ys.min() ?? 0, bottom = ys.max() ?? 1
        let range = max(0.05, bottom - top), middle = (top + bottom) / 2
        func x(_ t: Double) -> CGFloat {
            plot.minX + CGFloat((t - span.start) / max(0.01, span.end - span.start)) * plot.width
        }
        func y(_ value: Double) -> CGFloat { plot.midY + CGFloat((value - middle) / range) * plot.height }
        let line = samples.map { (time: $0.time, at: CGPoint(x: x($0.time), y: y($0.y))) }
        let parts = split(line, now: time)
        context.stroke(parts.future, with: .color(.white.opacity(0.24)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        if !parts.past.isEmpty { glowStroke(&context, parts.past, color: body1, width: 1.8 * scale, blur: 3 * scale) }
        // Kick and end on the time axis, with the flight time between them.
        let baseY = plot.maxY + axis * 0.45
        let kickX = x(flight.launch), endX = x(flight.end)
        let played = time >= flight.end
        var bracket = Path()
        bracket.move(to: CGPoint(x: kickX, y: baseY)); bracket.addLine(to: CGPoint(x: endX, y: baseY))
        context.stroke(bracket, with: .color((played ? head : .white).opacity(played ? 0.8 : 0.25)), lineWidth: 1)
        for tickX in [kickX, endX] {
            var tick = Path()
            tick.move(to: CGPoint(x: tickX, y: baseY - 3 * scale)); tick.addLine(to: CGPoint(x: tickX, y: baseY + 3 * scale))
            context.stroke(tick, with: .color(time >= flight.launch ? head : .white.opacity(0.4)), lineWidth: 1.2)
        }
        // Words are left out of thumbnails, where they would be too small to read.
        if scale > 0.7 {
            label("KICK", at: CGPoint(x: kickX - 3 * scale, y: baseY), in: &context, size: 7 * scale,
                  color: time >= flight.launch ? head : .white.opacity(0.45), anchor: .trailing)
            label(String(format: "%.2f s", flight.airTime), at: CGPoint(x: endX + 3 * scale, y: baseY), in: &context,
                  size: 7 * scale, color: played ? head : .white.opacity(0.45), anchor: .leading)
        }
        // The playhead.
        if time >= span.start, time <= span.end {
            var playhead = Path()
            let px = x(time)
            playhead.move(to: CGPoint(x: px, y: plot.minY)); playhead.addLine(to: CGPoint(x: px, y: plot.maxY))
            context.stroke(playhead, with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        }
        if let current = parts.current {
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 3 * scale))
                glow.fill(circle(current, 5 * scale), with: .color(body1))
            }
            context.fill(circle(current, 3 * scale), with: .color(.white))
        }
    }

    // MARK: - Kick Pulse: the shot as a heartbeat. Calm, then the kick spikes the trace.

    private func kickPulse(_ context: inout GraphicsContext, _ size: CGSize) {
        monitor(&context, size, fine: true)
        let scale = min(1, size.height / 110)
        let pad = min(10, size.height * 0.1)
        let plot = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        let samples = timeline
        let span = window
        // Speed across the picture, from positions smoothed over five frames.
        let count = samples.count
        func smoothed(_ index: Int) -> (x: Double, y: Double) {
            let slice = samples[max(0, index - 2)...min(count - 1, index + 2)]
            let n = Double(slice.count)
            return (slice.reduce(0) { $0 + $1.x } / n, slice.reduce(0) { $0 + $1.y } / n)
        }
        let speeds: [Double] = samples.indices.map { index in
            let a = max(0, index - 2), b = min(count - 1, index + 2)
            let dt = samples[b].time - samples[a].time
            guard dt > 0 else { return 0 }
            let pa = smoothed(a), pb = smoothed(b)
            return hypot(pb.x - pa.x, pb.y - pa.y) / dt
        }
        let peak = max(0.0001, speeds.max() ?? 1)
        let peakIndex = speeds.indices.max { speeds[$0] < speeds[$1] } ?? 0
        let baseline = plot.maxY - plot.height * 0.14
        func x(_ t: Double) -> CGFloat {
            plot.minX + CGFloat((t - span.start) / max(0.01, span.end - span.start)) * plot.width
        }
        func y(_ speed: Double) -> CGFloat { baseline - CGFloat(speed / peak) * (baseline - plot.minY - 6 * scale) }
        // A flat line leads in from the left edge, and out after the ball is lost.
        var line = [(time: span.start, at: CGPoint(x: plot.minX, y: baseline))]
        if let first = samples.first, first.time > span.start {
            line.append((first.time - 0.001, CGPoint(x: x(first.time), y: baseline)))
        }
        line += samples.indices.map { (time: samples[$0].time, at: CGPoint(x: x(samples[$0].time), y: y(speeds[$0]))) }
        line.append((flight.end + 0.05, CGPoint(x: x(flight.end + 0.05), y: baseline)))
        line.append((span.end, CGPoint(x: plot.maxX, y: baseline)))
        let parts = split(line, now: time)
        context.stroke(parts.future, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        if !parts.past.isEmpty { glowStroke(&context, parts.past, color: body1, width: 1.8 * scale, blur: 3.5 * scale) }
        // The spike: a dot at its peak, and KICK! when the playhead reaches it.
        let peakPoint = CGPoint(x: x(samples[peakIndex].time), y: y(speeds[peakIndex]))
        let reached = time >= samples[peakIndex].time
        context.fill(circle(peakPoint, 2.4 * scale), with: .color(reached ? head : .white.opacity(0.3)))
        if reached {
            let age = time - samples[peakIndex].time
            let pop = CGFloat(min(1, age / 0.12))
            let fade = age < 1.2 ? 1 : max(0.55, 1 - (age - 1.2))
            label("KICK!", at: CGPoint(x: peakPoint.x + 6 * scale, y: peakPoint.y), in: &context,
                  size: (8 + 3 * pop) * scale, color: head.opacity(fade), anchor: .leading)
        }
        if let current = parts.current {
            let beat = 1 + 0.25 * CGFloat(max(0, sin(time * 9)))
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 4 * scale))
                glow.fill(circle(current, 6 * scale * beat), with: .color(body1))
            }
            context.fill(circle(current, 3 * scale), with: .color(.white))
        }
    }

    // MARK: - Rainbow: the flight as a band of colour, like the juggling Rainbow Arcs

    private func rainbow(_ context: inout GraphicsContext, _ size: CGSize) {
        backdrop(&context, size)
        let scale = min(1, size.height / 110)
        let pad = min(18, size.height * 0.16)
        let lane = CGRect(x: pad, y: pad, width: size.width - pad * 2.4, height: size.height - pad * 2)
        let map = sideView(lane)
        let points = flight.points.indices.map(map)
        var ahead = Path()
        ahead.addLines(points)
        context.stroke(ahead, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, lineJoin: .round))
        let count = points.count
        func hue(_ index: Int) -> Double { (Double(index) / Double(max(1, count - 1)) * 0.82 + time * 0.12).truncatingRemainder(dividingBy: 1) }
        let current = min(flown, count - 1)
        if current < 0 {
            // Waiting for the kick: a ring of colour turns on the spot.
            for k in 0..<12 {
                let angle: Double = Double(k) / 12 * 2 * .pi + time * 2
                let ring: CGFloat = 7 * scale
                let at = CGPoint(x: points[0].x + CGFloat(cos(angle)) * ring, y: points[0].y + CGFloat(sin(angle)) * ring)
                context.fill(circle(at, 1.3 * scale), with: .color(Color(hue: Double(k) / 12, saturation: 0.7, brightness: 1)))
            }
            context.fill(circle(points[0], 2.6 * scale), with: .color(.white))
            return
        }
        var lit = context
        lit.blendMode = .plusLighter
        if current > 0 {
            let segments: [(path: Path, color: Color, width: CGFloat)] = (1...current).map { index in
                var segment = Path()
                segment.move(to: points[index - 1]); segment.addLine(to: points[index])
                let f = CGFloat(index) / CGFloat(max(1, current))
                return (segment, Color(hue: hue(index), saturation: 0.72, brightness: 1), (2 + 5 * f) * scale)
            }
            lit.drawLayer { glow in
                glow.addFilter(.blur(radius: 4 * scale))
                for segment in segments {
                    glow.stroke(segment.path, with: .color(segment.color.opacity(0.7)), style: StrokeStyle(lineWidth: segment.width * 2.2, lineCap: .round))
                }
            }
            for segment in segments {
                lit.stroke(segment.path, with: .color(segment.color), style: StrokeStyle(lineWidth: segment.width, lineCap: .round))
            }
        }
        let at = points[max(0, current)]
        if current < count - 1 {
            lit.fill(circle(at, 4 * scale), with: .color(.white))
        } else {
            // Landed: sparkles of every colour twinkle around the end.
            for k in 0..<14 {
                let angle = Double(k) / 14 * 2 * .pi
                let reach = CGFloat(8 + 10 * noise(k, 61)) * scale
                let sparkle = CGPoint(x: at.x + CGFloat(cos(angle)) * reach, y: at.y + CGFloat(sin(angle)) * reach * 0.8)
                let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * 7 + Double(k) * 1.7))
                lit.fill(circle(sparkle, 1.4 * scale), with: .color(Color(hue: Double(k) / 14, saturation: 0.65, brightness: 1).opacity(twinkle)))
            }
            lit.fill(circle(at, 3.4 * scale), with: .color(.white))
        }
    }

    // MARK: - Fireworks: the rocket flies with the ball and bursts when it lands, bigger the farther it went

    private func fireworks(_ context: inout GraphicsContext, _ size: CGSize) {
        backdrop(&context, size)
        let scale = min(1, size.height / 110)
        for index in 0..<Int(size.width * size.height / 520) {
            let point = CGPoint(x: noise(index, 71) * size.width, y: noise(index, 72) * size.height * 0.7)
            context.fill(circle(point, 0.5 + noise(index, 73) * 0.6), with: .color(.white.opacity(0.25 + 0.2 * sin(time * 2 + Double(index)))))
        }
        let ground = size.height - 8 * scale
        var groundLine = Path()
        groundLine.move(to: CGPoint(x: 0, y: ground)); groundLine.addLine(to: CGPoint(x: size.width, y: ground))
        context.stroke(groundLine, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
        // The rocket drifts the way the ball went across the picture.
        let xs: [Double] = flight.points.map { $0.x }
        let spanX = max(0.001, (xs.max() ?? 0) - (xs.min() ?? 0))
        let drift = CGFloat((flight.points[flight.points.count - 1].x - flight.points[0].x) / spanX)
        let startX = size.width * 0.5 - drift * size.width * 0.12
        let topY = size.height * 0.3
        let strength = CGFloat(min(1, max(0, (flight.depthRatio - 1) / 2.5)))
        var lit = context
        lit.blendMode = .plusLighter
        switch flight.phase(at: time) {
        case .waiting:
            // On the ground, its fuse fizzing.
            let base = CGPoint(x: startX, y: ground)
            let body = CGRect(x: base.x - 3 * scale, y: base.y - 15 * scale, width: 6 * scale, height: 14 * scale)
            context.fill(Path(roundedRect: body, cornerRadius: 3 * scale), with: .color(body1))
            var nose = Path()
            nose.move(to: CGPoint(x: body.minX, y: body.minY)); nose.addLine(to: CGPoint(x: body.midX, y: body.minY - 5 * scale))
            nose.addLine(to: CGPoint(x: body.maxX, y: body.minY)); nose.closeSubpath()
            context.fill(nose, with: .color(head))
            let frame = Int(time * 20)
            for k in 0..<4 {
                let sideways: CGFloat = CGFloat(noise(frame + k, 74) - 0.5) * 6 * scale
                let rise: CGFloat = CGFloat(noise(frame + k, 75)) * 4 * scale
                let spark = CGPoint(x: base.x + sideways, y: base.y + 1 * scale - rise)
                lit.fill(circle(spark, 0.9 * scale), with: .color(gold.opacity(0.9)))
            }
        case .flying:
            let progress = (time - flight.launch) / max(0.05, flight.airTime)
            let climb = CGFloat(1 - pow(1 - progress, 2))
            let rocket = CGPoint(x: startX + drift * size.width * 0.24 * climb, y: ground - (ground - topY) * climb)
            let from = CGPoint(x: startX, y: ground)
            lit.stroke(Path { $0.move(to: from); $0.addLine(to: rocket) },
                       with: .linearGradient(Gradient(colors: [.clear, gold.opacity(0.9)]), startPoint: from, endPoint: rocket), lineWidth: 1.8 * scale)
            lit.drawLayer { glow in
                glow.addFilter(.blur(radius: 4 * scale))
                glow.fill(circle(rocket, 6 * scale), with: .color(gold))
            }
            lit.fill(circle(rocket, 2.2 * scale), with: .color(.white))
        case .done:
            let center = CGPoint(x: startX + drift * size.width * 0.24, y: topY)
            let age = time - flight.end
            let opened = 1 - pow(1 - min(1, age / 0.7), 3)
            let reach = (24 + 30 * strength) * scale * CGFloat(opened)
            let fade = max(0, 1 - age / 2.8)
            let colors = [head, body1, tail, gold]
            let count = 28 + Int(strength * 20)
            var sparks: [(from: CGPoint, to: CGPoint, color: Color)] = []
            for ring in 0..<2 {
                let ringCount = ring == 0 ? count : count / 2
                for index in 0..<ringCount {
                    let angle = Double(index) / Double(ringCount) * 2 * .pi + Double(ring) * 0.3
                    let jitter = 0.85 + 0.3 * noise(index, 80 + ring)
                    let distance = reach * (ring == 0 ? 1 : 0.55) * CGFloat(jitter)
                    let dir = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)) * 0.88)
                    let drop = CGFloat(10 * age * age) * scale
                    let tip = CGPoint(x: center.x + dir.x * distance, y: center.y + dir.y * distance + drop)
                    let length = min(10 * scale, distance * 0.45) * CGFloat(max(0.15, 1 - age / 1.2))
                    sparks.append((CGPoint(x: tip.x - dir.x * length, y: tip.y - dir.y * length), tip,
                                   ring == 0 ? colors[index % colors.count] : ivory))
                }
            }
            lit.drawLayer { glow in
                glow.addFilter(.blur(radius: 4 * scale))
                for spark in sparks {
                    glow.stroke(Path { $0.move(to: spark.from); $0.addLine(to: spark.to) }, with: .color(spark.color.opacity(fade * 0.8)), lineWidth: 2.4)
                }
            }
            for spark in sparks {
                lit.stroke(Path { $0.move(to: spark.from); $0.addLine(to: spark.to) }, with: .color(spark.color.opacity(fade)),
                           style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                lit.fill(circle(spark.to, 1.1 * scale), with: .color(.white.opacity(fade * 0.85)))
            }
            if age < 0.18 {
                lit.drawLayer { flash in
                    flash.addFilter(.blur(radius: 7))
                    flash.fill(circle(center, 12 * scale), with: .color(.white.opacity(1 - age / 0.18)))
                }
            }
            let appear = min(1, max(0, (age - 0.25) / 0.25))
            if appear > 0 {
                pill(String(format: "%.1f× FARTHER", flight.depthRatio), at: CGPoint(x: size.width / 2, y: ground - 4 * scale),
                     in: &context, size: 8.5 * scale, fill: gold.opacity(appear), anchor: UnitPoint(x: 0.5, y: 1))
            }
        }
    }

    // MARK: - Tape Measure: a tape unrolls with the roll's distance (ARKit, experimental)

    private func tape(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let distance else {
            label("Record a roll in the app to measure it", at: CGPoint(x: size.width / 2, y: size.height / 2), in: &context,
                  size: 9, weight: .medium, color: .white.opacity(0.55))
            return
        }
        let scale = min(1, size.height / 110)
        let reading = distance.state(at: time)
        let metres = reading.distanceM ?? 0
        let longest = max(metres, distance.samples.compactMap(\.distanceM).max() ?? 0)
        let span = max(1, (longest * 2).rounded(.up) / 2 + 0.5)
        let caseSize = 34 * scale
        let caseRect = CGRect(x: 6, y: size.height * 0.6 - caseSize / 2, width: caseSize, height: caseSize)
        let start = caseRect.maxX - 2
        let usable = size.width - start - 22 * scale
        func x(_ value: Double) -> CGFloat { start + CGFloat(value / span) * usable }
        let tapeTop = caseRect.midY - 7 * scale, tapeHeight = 14 * scale
        let end = x(metres)
        // The tape, with a tick every 10 cm and a number every metre.
        if end > start {
            context.fill(Path(roundedRect: CGRect(x: start, y: tapeTop, width: end - start, height: tapeHeight), cornerRadius: 2),
                         with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.3), Color(red: 0.93, green: 0.7, blue: 0.12)]),
                                               startPoint: CGPoint(x: 0, y: tapeTop), endPoint: CGPoint(x: 0, y: tapeTop + tapeHeight)))
            var step = 1
            while Double(step) * 0.1 <= metres + 0.0001 {
                let value = Double(step) * 0.1
                let whole = step % 10 == 0, half = step % 5 == 0
                let length = (whole ? 9 : half ? 6 : 3.5) * scale
                var mark = Path()
                mark.move(to: CGPoint(x: x(value), y: tapeTop)); mark.addLine(to: CGPoint(x: x(value), y: tapeTop + length))
                context.stroke(mark, with: .color(.black.opacity(0.75)), lineWidth: whole ? 1.2 : 0.7)
                if whole {
                    label("\(step / 10)", at: CGPoint(x: x(value) + 2, y: tapeTop + tapeHeight - 1), in: &context,
                          size: 7 * scale, weight: .heavy, color: .black.opacity(0.8), anchor: .bottomLeading)
                }
                step += 1
            }
            context.fill(Path(CGRect(x: end - 2 * scale, y: tapeTop - 3 * scale, width: 3 * scale, height: tapeHeight + 6 * scale)),
                         with: .color(Color(white: 0.25)))
        }
        // The case.
        context.fill(Path(roundedRect: caseRect, cornerRadius: 8 * scale), with: .linearGradient(
            Gradient(colors: [Color(red: 1, green: 0.84, blue: 0.24), Color(red: 0.85, green: 0.6, blue: 0.08)]),
            startPoint: CGPoint(x: caseRect.minX, y: caseRect.minY), endPoint: CGPoint(x: caseRect.maxX, y: caseRect.maxY)))
        context.fill(circle(CGPoint(x: caseRect.midX, y: caseRect.midY), caseSize * 0.32), with: .color(Color(white: 0.12)))
        // The ball rolls ahead of the tape, turning as it goes.
        let ballRadius = 8 * scale
        sphere(&context, at: CGPoint(x: max(start + ballRadius, end + ballRadius + 1), y: tapeTop - ballRadius + tapeHeight / 2 - 6 * scale),
               radius: ballRadius, spin: metres / 0.22 * 2)
        let value = reading.status == .waiting ? "READY" : String(format: "%.2f m", metres)
        let finished = reading.status == .finished
        let tagX = min(size.width - 8, max(start + 40, end))
        pill(finished ? "\(value)  ·  FINAL" : value, at: CGPoint(x: tagX, y: tapeTop - 22 * scale),
             in: &context, size: 10 * scale, fill: finished ? gold : body1, anchor: UnitPoint(x: tagX > size.width - 60 ? 1 : 0.5, y: 1))
        if reading.status == .paused {
            label("PAUSED", at: CGPoint(x: size.width - 8, y: size.height - 8), in: &context, size: 8 * scale,
                  color: .orange, anchor: .bottomTrailing)
        }
    }
}

/// Loops a graph over a sample shot, for thumbnails: a beat of rest, the kick, the flight, a hold.
struct ShotGraphThumbnail: View {
    let style: ShotGraphStyle
    var palette: [Color] = ShotTrailStyle.limeRibbon.palette
    var flight: ShotFlight = .sample
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let start = style == .tape ? 0 : max(flight.lead.first?.time ?? flight.launch, flight.launch - 0.4)
            let finish = style == .tape ? 3.2 : flight.end + 1.3
            let cycle = finish - start
            let local = reduceMotion ? cycle : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            ShotGraph(style: style, flight: flight, time: start + local, palette: palette,
                      distance: style == .tape ? .sampleRoll : nil)
        }
    }
}

extension BallDistanceTimeline {
    /// A 2.4 m roll for the Tape Measure thumbnail, starting half a second in.
    static let sampleRoll: BallDistanceTimeline = {
        let samples = stride(from: 0.0, through: 1.6, by: 0.05).map { t in
            Sample(time: t + 0.5, distanceM: 2.4 * (1 - pow(1 - t / 1.6, 2)), status: .tracking)
        } + [Sample(time: 2.15, distanceM: 2.4, status: .finished)]
        return BallDistanceTimeline(samples: samples)
    }()
}

/// Under the video: the graph, then how long the ball was followed, how far it flew away and
/// how it curved.
struct ShotFlightPanel: View {
    let style: ShotGraphStyle
    let flight: ShotFlight?
    let time: Double
    var showGraph = true
    var palette: [Color] = ShotTrailStyle.limeRibbon.palette
    var distance: BallDistanceTimeline? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showGraph, let flight {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(style.title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1)
                        Text(style.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(status(flight)).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TrainingHomeStyle.lime)
                            .contentTransition(.interpolate)
                            .animation(reduceMotion ? nil : SessionMotion.snap, value: status(flight))
                        Text(style.measure).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    }
                }
                ShotGraph(style: style, flight: flight, time: time, palette: palette, distance: distance)
                    .frame(height: 112)
                    .id(style)
                    .transition(.blurReplace)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(style.title): \(style.subtitle)")
                    .accessibilityIdentifier("shot-graph")
                Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
            }
            HStack(spacing: 12) {
                metric("FLIGHT TRACKED", value: airTime, alignment: .leading)
                    .accessibilityIdentifier("shot-air-time")
                metric("FARTHER", value: farther, alignment: .center)
                    .accessibilityIdentifier("shot-depth")
                metric("CURVE", value: curve, alignment: .trailing)
                    .accessibilityIdentifier("shot-curve")
            }
        }
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : SessionMotion.settle, value: style)
    }

    private func status(_ flight: ShotFlight) -> String {
        if style == .tape, let distance { return distance.state(at: time).status.label.uppercased() }
        switch flight.phase(at: time) {
        case .waiting: return "BEFORE THE KICK"
        case .flying: return "IN FLIGHT"
        case .done: return "AFTER THE SHOT"
        }
    }

    /// Counts up while the ball flies, then holds the full flight.
    private var airTime: String {
        guard let flight else { return "—" }
        switch flight.phase(at: time) {
        case .waiting: return "—"
        case .flying: return String(format: "%.2f s", time - flight.launch)
        case .done: return String(format: "%.2f s", flight.airTime)
        }
    }

    /// How many times farther from the camera the ball is than at the kick.
    private var farther: String {
        guard let flight else { return "—" }
        switch flight.phase(at: time) {
        case .waiting: return "—"
        case .flying: return String(format: "%.1f×", flight.depth(at: time))
        case .done: return String(format: "%.1f×", flight.depthRatio)
        }
    }

    /// Revealed once the ball has passed its widest point, so the replay keeps its moment.
    private var curve: String {
        guard let flight, time >= flight.points[min(flight.points.count - 1, flight.bendIndex)].time else { return "—" }
        return flight.curveLabel
    }

    private func metric(_ title: String, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .medium)).tracking(0.5).foregroundStyle(.white.opacity(0.72))
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }
}

/// The Graph page of the shot's Customize tray, laid out like the juggling one.
struct ShotGraphPicker: View {
    @Binding var style: ShotGraphStyle
    @Binding var showGraph: Bool
    let flight: ShotFlight?
    let time: Double
    var palette: [Color] = ShotTrailStyle.limeRibbon.palette
    var distance: BallDistanceTimeline? = nil
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Show shot graph").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Show shot graph", isOn: $showGraph.animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)))
                    .labelsHidden().fixedSize().tint(SessionStyle.mint)
                    .accessibilityIdentifier("shot-graph-show")
            }.padding(.horizontal, 16)

            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                        Text("In this shot · \(ExportPreviewTime.label(at: time))")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Button(action: onTogglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel(isPlaying ? "Pause graph preview" : "Play graph preview")
                    .accessibilityIdentifier("shot-graph-play")
                }
                Group {
                    if let flight {
                        ShotGraph(style: style, flight: flight, time: time, palette: palette, distance: distance)
                    } else {
                        Text("No flight found in this shot").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 104)
                .opacity(showGraph ? 1 : 0.3)
                .id(style)
                .transition(.blurReplace)
            }
            .padding(14)
            .background(Color(red: 0.045, green: 0.065, blue: 0.067), in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .padding(.horizontal, 16)
            .animation(reduceMotion ? nil : SessionMotion.settle, value: style)

            HStack {
                Text("Graph styles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(ShotGraphStyle.available(hasDistance: distance != nil).count) styles · Swipe to explore")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }.padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ShotGraphStyle.available(hasDistance: distance != nil)) { option in
                        Button {
                            style = option; showGraph = true
                        } label: {
                            ShotGraphOption(style: option, selected: style == option, palette: palette)
                        }
                        .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.95))
                        .accessibilityLabel(option.title + (option == .comet ? ", Default" : ""))
                        .accessibilityHint(option.caption)
                        .accessibilityAddTraits(style == option ? .isSelected : [])
                        .accessibilityIdentifier("shot-graph-\(option.rawValue)")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
        }
        .sensoryFeedback(.selection, trigger: style)
    }
}

private struct ShotGraphOption: View {
    let style: ShotGraphStyle
    let selected: Bool
    let palette: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ShotGraphThumbnail(style: style, palette: palette)
                .frame(height: 66)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(style.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(.black, SessionStyle.mint)
                        .transition(.sessionPop(scale: 0.2))
                }
            }
            Text(style == .comet ? "DEFAULT" : style.measure)
                .font(.system(size: 7, weight: .medium)).tracking(0.6)
                .foregroundStyle(style == .comet ? SessionStyle.mint : .white.opacity(0.45))
        }
        .padding(10).frame(width: 146)
        .background(Color(red: 0.05, green: 0.075, blue: 0.077), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.14), lineWidth: selected ? 1.3 : 0.5)
        }
        .foregroundStyle(.white).contentShape(.rect(cornerRadius: 16))
        .animation(SessionMotion.snap, value: selected)
    }
}
