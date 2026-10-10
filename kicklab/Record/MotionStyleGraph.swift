import SwiftUI

/// Native renderers for the replay HUD's motion styles. Everything is derived from the
/// playhead and measured data, so pausing, seeking and replaying are deterministic.
struct MotionStyleGraph: View {
    let style: MotionStyle
    let snapshot: MotionStyleSnapshot
    var sourceAspect: CGFloat = 9.0 / 16.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lime = Color(cgColor: NormalCounterAppearance.lime)
    private let mint = Color(red: 0.48, green: 0.97, blue: 0.73)
    private let ivory = Color(red: 0.99, green: 0.98, blue: 0.88)
    private let gold = Color(red: 1, green: 0.8, blue: 0.28)
    private let coral = Color(red: 1, green: 0.36, blue: 0.45)

    var body: some View {
        if style == .ballMotion {
            CaptureMotionGraph(layout: snapshot.graph, touchTimes: snapshot.touchTimes)
        } else {
            Canvas { context, size in
                switch style {
                case .ballMotion: break
                case .comet: comet(&context, size)
                case .bounceRun: bounce(&context, size)
                case .heartbeat: heartbeat(&context, size)
                case .melody: melody(&context, size)
                case .fireworks: fireworks(&context, size)
                case .skyMeter: skyMeter(&context, size)
                case .combo: combo(&context, size)
                case .metronome: metronome(&context, size)
                case .rainbowArcs: rainbow(&context, size)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var now: Double { snapshot.graph.time }
    private var lastTouchAge: Double? { snapshot.played.last.map { now - $0 } }

    private func dot(_ context: inout GraphicsContext, at p: CGPoint, radius: CGFloat, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(color))
    }

    private func line(_ context: inout GraphicsContext, from a: CGPoint, to b: CGPoint,
                      color: Color, width: CGFloat = 1) {
        var path = Path(); path.move(to: a); path.addLine(to: b)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func text(_ value: String, at p: CGPoint, in context: inout GraphicsContext, size: CGFloat = 9,
                      color: Color = .white.opacity(0.7), anchor: UnitPoint = .center) {
        context.draw(Text(value).font(.system(size: size, weight: .medium)).monospacedDigit().foregroundStyle(color),
                     at: p, anchor: anchor)
    }

    private func arrow(_ context: inout GraphicsContext, from a: CGPoint, to b: CGPoint,
                       color: Color, width: CGFloat = 1.4, head: CGFloat = 5) {
        line(&context, from: a, to: b, color: color, width: width)
        let angle = atan2(b.y - a.y, b.x - a.x)
        for side in [-1.0, 1.0] {
            let tip = CGPoint(x: b.x - cos(angle + side * .pi / 5) * head,
                              y: b.y - sin(angle + side * .pi / 5) * head)
            line(&context, from: tip, to: b, color: color, width: width)
        }
    }

    private func comet(_ context: inout GraphicsContext, _ size: CGSize) {
        let graph = snapshot.graph
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: 4 + p.x * (size.width - 8), y: 5 + p.y * (size.height - 12)) }
        var previous: CaptureGraphLayout.Sample?
        for sample in graph.samples {
            defer { previous = sample }
            guard let previous, let a = previous.point, let b = sample.point,
                  sample.time - previous.time <= 0.3 else { continue }
            let played = sample.time <= graph.time
            line(&context, from: pixel(a), to: pixel(b), color: played ? lime.opacity(0.8) : .white.opacity(0.24), width: 1)
            let age = graph.time - sample.time
            if played, age < 0.35, graph.currentPoint != nil {
                let strength = 1 - age / 0.35
                var glow = context
                glow.addFilter(.blur(radius: 2.5))
                line(&glow, from: pixel(a), to: pixel(b), color: lime.opacity(strength * 0.65), width: 5 * strength)
                line(&context, from: pixel(a), to: pixel(b), color: lime, width: 0.8 + 2 * strength)
            }
        }
        if let p = graph.currentPoint { dot(&context, at: pixel(p), radius: 3.2, color: .white) }
    }


    private func glow(_ context: GraphicsContext, radius: CGFloat = 3) -> GraphicsContext {
        var copy = context
        copy.addFilter(.blur(radius: radius))
        return copy
    }

    private func label(_ value: String, at p: CGPoint, in context: inout GraphicsContext, size: CGFloat,
                       weight: Font.Weight = .semibold, color: Color = .white, anchor: UnitPoint = .center,
                       design: Font.Design = .default) {
        context.draw(Text(value).font(.system(size: size, weight: weight, design: design)).monospacedDigit()
            .foregroundStyle(color), at: p, anchor: anchor)
    }

    private func symbol(_ name: String, in rect: CGRect, color: Color, in context: inout GraphicsContext) {
        var image = context.resolve(Image(systemName: name))
        image.shading = .color(color)
        context.draw(image, in: rect)
    }

    private func sphere(_ context: inout GraphicsContext, _ rect: CGRect) {
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.white, ivory, Color(red: 0.72, green: 0.78, blue: 0.74)]),
            center: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.3),
            startRadius: 0, endRadius: max(rect.width, rect.height) * 0.75))
    }

    // MARK: Bounce Run: a tiny platformer. Every touch is a hop to the next pad, at your real height.

    private func bounce(_ context: inout GraphicsContext, _ size: CGSize) {
        let baseline = size.height - 13, spacing = size.width / 4
        let padWidth = min(44, spacing * 0.52), padHeight: CGFloat = 7
        let phase = snapshot.bounce?.phase ?? 0
        let hops = snapshot.played.count
        let travel = (Double(hops) + phase) * Double(spacing)
        // Parallax hills scroll slower than the pads.
        for (depth, alpha) in [(0.22, 0.05), (0.45, 0.09)] {
            var hills = Path()
            hills.move(to: CGPoint(x: 0, y: baseline))
            for x in stride(from: 0.0, through: Double(size.width), by: 4) {
                let world = x + travel * depth
                let rise = 10 + 7 * sin(world / 37) + 5 * sin(world / 17 + 1.3)
                hills.addLine(to: CGPoint(x: x, y: Double(baseline) - rise * (depth > 0.3 ? 1.3 : 2)))
            }
            hills.addLine(to: CGPoint(x: size.width, y: baseline)); hills.closeSubpath()
            context.fill(hills, with: .color(mint.opacity(alpha)))
        }
        line(&context, from: CGPoint(x: 0, y: baseline), to: CGPoint(x: size.width, y: baseline), color: mint.opacity(0.35), width: 0.8)

        let ballX = size.width * 0.58
        let startX = ballX - CGFloat(phase) * spacing
        let landed = lastTouchAge ?? 9
        for index in -3...3 {
            let x = startX + CGFloat(index) * spacing
            guard x > -padWidth, x < size.width + padWidth else { continue }
            let rect = CGRect(x: x - padWidth / 2, y: baseline - padHeight, width: padWidth, height: padHeight)
            let pad = Path(roundedRect: rect, cornerRadius: padHeight / 2)
            let current = index == 0 && hops > 0
            let flash = current ? exp(-landed * 5) : 0
            if flash > 0.02 {
                let halo = glow(context, radius: 6)
                halo.fill(Path(roundedRect: rect.insetBy(dx: -4, dy: -3), cornerRadius: 6), with: .color(lime.opacity(flash)))
            }
            context.fill(pad, with: .linearGradient(Gradient(colors: index <= 0 ? [mint, mint.opacity(0.7)] : [mint.opacity(0.35), mint.opacity(0.15)]),
                                                     startPoint: rect.origin, endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            if flash > 0.02 { context.fill(pad, with: .color(lime.opacity(flash))) }
            context.stroke(pad, with: .color(ivory.opacity(index <= 0 ? 0.6 : 0.3)), lineWidth: 0.6)
            let number = hops + index
            if number > 0 {
                label("\(number)", at: CGPoint(x: x, y: baseline + 7), in: &context, size: 7.5, weight: .medium,
                      color: .white.opacity(index == 0 ? 0.9 : 0.45))
            }
        }
        guard let bounce = snapshot.bounce, hops > 0 else {
            label("Waiting for the first touch", at: CGPoint(x: size.width / 2, y: baseline / 2), in: &context,
                  size: 9, weight: .medium, color: .white.opacity(0.6))
            return
        }
        // "+1" floats off the pad just landed on, with a puff of dust.
        if landed < 0.6 {
            let rise = CGFloat(landed) * 26
            label("+1", at: CGPoint(x: startX, y: baseline - padHeight - 10 - rise), in: &context, size: 10,
                  weight: .heavy, color: lime.opacity(1 - landed / 0.6))
        }
        if landed < 0.3 {
            for i in 0..<6 {
                let side: CGFloat = i < 3 ? -1 : 1, k = CGFloat(i % 3)
                let reach = CGFloat(landed / 0.3) * (8 + k * 5)
                dot(&context, at: CGPoint(x: startX + side * (padWidth * 0.3 + reach), y: baseline - padHeight - 1 - k * 1.5 - reach * 0.3),
                    radius: 1.3, color: ivory.opacity(0.7 * (1 - landed / 0.3)))
            }
        }
        let radius = min(8.5, size.height * 0.1)
        let floor = baseline - padHeight - radius
        let lift = CGFloat(snapshot.lift ?? bounce.height)
        let y = floor - lift * max(0, floor - radius - 6)
        // The arc so far, from the take-off pad to the ball.
        var arc = Path()
        arc.move(to: CGPoint(x: startX, y: floor))
        arc.addQuadCurve(to: CGPoint(x: ballX, y: y), control: CGPoint(x: (startX + ballX) / 2, y: y - 6))
        context.stroke(arc, with: .color(lime.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 4]))
        let shadowWidth = 18 * (1 - lift * 0.6)
        context.fill(Path(ellipseIn: CGRect(x: ballX - shadowWidth / 2, y: baseline - padHeight - 2.5, width: shadowWidth, height: 3)),
                     with: .color(.black.opacity(0.35 * (1 - Double(lift) * 0.5))))
        let scale = reduceMotion ? CGSize(width: 1, height: 1) : bounce.scale
        let rect = CGRect(x: ballX - radius * scale.width, y: y + radius - 2 * radius * scale.height,
                          width: 2 * radius * scale.width, height: 2 * radius * scale.height)
        sphere(&context, rect)
    }

    // MARK: Heartbeat: a heart monitor. Every touch is a beat; steady juggling, a steady pulse.

    private func heartbeat(_ context: inout GraphicsContext, _ size: CGSize) {
        let compact = size.width < 230
        let window = compact ? 2.5 : 4.0, panel: CGFloat = compact ? 44 : 74
        let plot = size.width - panel
        for x in stride(from: CGFloat(0), through: plot, by: 12) {
            line(&context, from: CGPoint(x: x, y: 2), to: CGPoint(x: x, y: size.height - 2),
                 color: mint.opacity(x.truncatingRemainder(dividingBy: 60) < 1 ? 0.1 : 0.04), width: 0.5)
        }
        for y in stride(from: CGFloat(2), through: size.height - 2, by: 12) {
            line(&context, from: CGPoint(x: 0, y: y), to: CGPoint(x: plot, y: y), color: mint.opacity(0.04), width: 0.5)
        }
        let mid = size.height * 0.64, amplitude = mid - 6
        let beats = snapshot.played.filter { $0 > now - window - 0.4 }
        let strengths = Dictionary(snapshot.arcs.map { ($0.start, $0.lift) }, uniquingKeysWith: { a, _ in a })
        func strength(_ touch: Double) -> Double {
            if let lift = strengths[touch] { return 0.45 + 0.55 * lift }
            if let flight = snapshot.flight, flight.start == touch { return 0.45 + 0.55 * flight.peak }
            return 0.7
        }
        func g(_ x: Double, _ s: Double) -> Double { exp(-(x / s) * (x / s)) }
        func signal(_ t: Double) -> Double {
            beats.reduce(0) { sum, touch in
                let dt = t - touch
                guard dt > -0.15, dt < 0.3 else { return sum }
                let shape = 0.1 * g(dt + 0.09, 0.022) - 0.14 * g(dt + 0.014, 0.007) + g(dt, 0.011)
                    - 0.32 * g(dt - 0.022, 0.01) + 0.22 * g(dt - 0.16, 0.035)
                return sum + shape * strength(touch)
            }
        }
        var trace = Path()
        let steps = Int(plot / 1.2)
        for i in 0...steps {
            let x = CGFloat(i) * 1.2, t = now - window + Double(x / plot) * window
            let p = CGPoint(x: x, y: mid - CGFloat(signal(t)) * amplitude)
            if i == 0 { trace.move(to: p) } else { trace.addLine(to: p) }
        }
        let fade = GraphicsContext.Shading.linearGradient(Gradient(colors: [lime.opacity(0.05), lime.opacity(0.5), lime]),
                                                          startPoint: .zero, endPoint: CGPoint(x: plot, y: 0))
        glow(context, radius: 3).stroke(trace, with: fade, style: StrokeStyle(lineWidth: 3.2, lineJoin: .round))
        context.stroke(trace, with: fade, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        let head = CGPoint(x: plot, y: mid - CGFloat(signal(now)) * amplitude)
        glow(context, radius: 4).fill(Path(ellipseIn: CGRect(x: head.x - 5, y: head.y - 5, width: 10, height: 10)), with: .color(lime))
        dot(&context, at: head, radius: 2.4, color: .white)

        let flat = (lastTouchAge ?? 9) > 2
        let pulse = flat ? 1 : 1 + 0.4 * exp(-(lastTouchAge ?? 9) * 9)
        let heart = (compact ? 12 : 15) * pulse
        let center = CGPoint(x: plot + panel / 2, y: size.height * 0.36)
        if !flat { glow(context, radius: 5).fill(Path(ellipseIn: CGRect(x: center.x - heart * 0.6, y: center.y - heart * 0.6, width: heart * 1.2, height: heart * 1.2)), with: .color(coral.opacity(0.5 * (pulse - 1) / 0.4))) }
        symbol("heart.fill", in: CGRect(x: center.x - heart / 2, y: center.y - heart / 2, width: heart, height: heart * 0.92),
               color: flat ? .white.opacity(0.3) : coral, in: &context)
        let rate = snapshot.rhythm.perMinute.map { String(format: "%.0f", $0) } ?? "—"
        label(flat ? "—" : rate, at: CGPoint(x: center.x, y: size.height * 0.68), in: &context, size: compact ? 16 : 20, weight: .bold, design: .rounded)
        label("PER MIN", at: CGPoint(x: center.x, y: size.height * 0.9), in: &context, size: 7, weight: .medium, color: .white.opacity(0.55))
    }

    // MARK: Melody: each bounce becomes a note on a staff, pitched by how high the ball went.

    private func melody(_ context: inout GraphicsContext, _ size: CGSize) {
        let window = 6.0, top: CGFloat = 12, gap = (size.height - 30) / 4
        let bottomLine = top + 4 * gap
        for i in 0...4 {
            let y = top + CGFloat(i) * gap
            line(&context, from: CGPoint(x: 6, y: y), to: CGPoint(x: size.width - 6, y: y), color: .white.opacity(0.22), width: 0.7)
        }
        label("𝄞", at: CGPoint(x: 15, y: top + 2 * gap + 2), in: &context, size: gap * 4.6, weight: .regular, color: .white.opacity(0.75))
        let left: CGFloat = 34, right = size.width - 18
        func x(_ t: Double) -> CGFloat { left + CGFloat((t - (now - window)) / window) * (right - left) }
        let range = snapshot.arcRange
        func step(_ lift: Double) -> Int {
            Int((min(1, max(0, (lift - range.lowerBound) / (range.upperBound - range.lowerBound))) * 8).rounded())
        }
        func y(_ step: Int) -> CGFloat { bottomLine - CGFloat(step) * gap / 2 }
        func tone(_ step: Int) -> Color { step >= 6 ? gold : step >= 3 ? lime : mint }

        let notes = snapshot.arcs.filter { x($0.apex) > left - 4 }
        let stemLength = gap * 2.5
        var previousTip: CGPoint?, previousApex: Double?, previousDown: Bool?
        for (index, note) in notes.enumerated() {
            let s = step(note.lift), head = CGPoint(x: x(note.apex), y: y(s))
            let age = now - note.end
            let pop = age < 0.35 && !reduceMotion ? 1 + 0.6 * (1 - age / 0.35) : 1
            // Notes on the upper half take their stem down the left side, as in printed music.
            let down = s >= 4
            let tip = down ? CGPoint(x: head.x - 4.4, y: head.y + stemLength) : CGPoint(x: head.x + 4.4, y: head.y - stemLength)
            line(&context, from: CGPoint(x: tip.x, y: head.y + (down ? 1 : -1)), to: tip, color: tone(s), width: 1.2)
            if let previousTip, let previousApex, previousDown == down, note.apex - previousApex < 0.95 {
                let thick: CGFloat = down ? -3.2 : 3.2
                var beam = Path()
                beam.move(to: previousTip); beam.addLine(to: tip)
                beam.addLine(to: CGPoint(x: tip.x, y: tip.y + thick)); beam.addLine(to: CGPoint(x: previousTip.x, y: previousTip.y + thick))
                beam.closeSubpath()
                context.fill(beam, with: .linearGradient(Gradient(colors: [tone(step(notes[index - 1].lift)), tone(s)]),
                                                          startPoint: previousTip, endPoint: tip))
            } else {
                var flag = Path()
                flag.move(to: tip)
                let bend: CGFloat = down ? -1 : 1
                flag.addQuadCurve(to: CGPoint(x: tip.x + 6, y: tip.y + 11 * bend), control: CGPoint(x: tip.x + 7, y: tip.y + 4 * bend))
                context.stroke(flag, with: .color(tone(s)), lineWidth: 1.4)
            }
            var headContext = context
            headContext.translateBy(x: head.x, y: head.y)
            headContext.rotate(by: .degrees(-22))
            headContext.scaleBy(x: pop, y: pop)
            headContext.fill(Path(ellipseIn: CGRect(x: -5, y: -3.6, width: 10, height: 7.2)), with: .color(tone(s)))
            if age < 0.6 {
                label("♪", at: CGPoint(x: head.x + 10, y: max(7, head.y - 10 - CGFloat(age) * 30)), in: &context, size: 10,
                      color: tone(s).opacity(1 - age / 0.6))
            }
            previousTip = tip; previousApex = note.apex; previousDown = down
        }
        // The note being played right now: an open head that follows the ball.
        line(&context, from: CGPoint(x: x(now), y: top - 4), to: CGPoint(x: x(now), y: bottomLine + 4), color: .white.opacity(0.18), width: 0.8)
        if let flight = snapshot.flight {
            let s = step(flight.peak)
            var open = context
            open.translateBy(x: x(now), y: y(s)); open.rotate(by: .degrees(-22))
            open.stroke(Path(ellipseIn: CGRect(x: -5, y: -3.6, width: 10, height: 7.2)), with: .color(.white.opacity(0.85)), lineWidth: 1.4)
        } else if notes.isEmpty {
            label("Your first bounce plays the first note", at: CGPoint(x: size.width / 2, y: bottomLine + 11), in: &context,
                  size: 8.5, weight: .medium, color: .white.opacity(0.55))
        }
    }

    // MARK: Fireworks: every bounce launches one. Higher bounce, higher and bigger; your best goes gold.

    private func fireworks(_ context: inout GraphicsContext, _ size: CGSize) {
        let ground = size.height - 4
        let colors = [lime, mint, coral, Color(red: 0.4, green: 0.82, blue: 1), Color(red: 0.8, green: 0.55, blue: 1)]
        func x(_ number: Int) -> CGFloat {
            let spread = (Double(number) * 0.61803398875).truncatingRemainder(dividingBy: 1)
            return size.width * CGFloat(0.12 + 0.76 * spread)
        }
        func altitude(_ lift: Double) -> CGFloat { ground - 14 - CGFloat(lift) * (ground - 28) }
        line(&context, from: CGPoint(x: 0, y: ground), to: CGPoint(x: size.width, y: ground), color: .white.opacity(0.12), width: 0.6)

        var bursts = snapshot.arcs.map { ($0.number, $0.apex, $0.lift) }
        if let flight = snapshot.flight {
            let number = snapshot.played.count
            if flight.falling {
                bursts.append((number, flight.apex, flight.peak))
            } else {
                // The rocket climbs with the ball.
                let top = CGPoint(x: x(number), y: altitude(flight.lift))
                context.stroke(Path { $0.move(to: CGPoint(x: top.x, y: ground)); $0.addLine(to: top) },
                               with: .linearGradient(Gradient(colors: [.clear, gold.opacity(0.9)]),
                                                     startPoint: CGPoint(x: top.x, y: ground), endPoint: top),
                               lineWidth: 1.6)
                glow(context, radius: 4).fill(Path(ellipseIn: CGRect(x: top.x - 5, y: top.y - 5, width: 10, height: 10)), with: .color(gold))
                for k in 1...4 {
                    let spark = CGPoint(x: top.x + CGFloat(sin(now * 31 + Double(k) * 2.1)) * 3, y: top.y + CGFloat(k) * 5)
                    dot(&context, at: spark, radius: 0.9, color: gold.opacity(0.8 - Double(k) * 0.15))
                }
                dot(&context, at: top, radius: 2, color: .white)
            }
        }
        var lit = context
        lit.blendMode = .plusLighter
        let haze = glow(lit, radius: 4)
        for (number, apex, lift) in bursts {
            let age = now - apex
            guard age >= 0, age < 1.8 else { continue }
            let record = lift >= snapshot.best - 0.001 && lift > 0.2
            let tint = record ? gold : colors[number % colors.count]
            let center = CGPoint(x: x(number), y: altitude(lift))
            let opened = 1 - pow(1 - min(1, age / 0.75), 3)
            let reach = (16 + 40 * CGFloat(lift)) * CGFloat(opened)
            let fade = pow(max(0, 1 - age / 1.8), 1.3)
            let count = 26 + Int(lift * 18) + (record ? 12 : 0)
            let drop = CGFloat(12 * age * age)
            for ring in 0..<2 {
                let scale: CGFloat = ring == 0 ? 1 : 0.55, ink = ring == 0 ? tint : ivory
                for i in 0..<(ring == 0 ? count : count / 2) {
                    let angle = Double(i) / Double(ring == 0 ? count : count / 2) * 2 * .pi + Double(number) + Double(ring) * 0.3
                    let jitter = 0.86 + 0.28 * ((Double(i * 37 + number * 11).truncatingRemainder(dividingBy: 10)) / 10)
                    let d = reach * scale * CGFloat(jitter)
                    let dir = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)) * 0.88)
                    let p = CGPoint(x: center.x + dir.x * d, y: center.y + dir.y * d + drop)
                    // Each spark streaks outward, its tail shortening as it slows.
                    let tail = min(11, d * 0.45) * CGFloat(max(0.15, 1 - age / 1.1))
                    let from = CGPoint(x: p.x - dir.x * tail, y: p.y - dir.y * tail)
                    let twinkle = age > 0.9 ? 0.55 + 0.45 * sin(age * 38 + Double(i)) : 1
                    let alpha = fade * twinkle * (ring == 0 ? 1 : 0.7)
                    haze.stroke(Path { $0.move(to: from); $0.addLine(to: p) }, with: .color(ink.opacity(alpha * 0.8)), lineWidth: 2.4)
                    lit.stroke(Path { $0.move(to: from); $0.addLine(to: p) },
                               with: .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(alpha)]), startPoint: from, endPoint: p),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    dot(&lit, at: p, radius: record ? 1.5 : 1.2, color: Color.white.opacity(alpha * 0.85))
                }
            }
            if age < 0.18 {
                glow(lit, radius: 7).fill(Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)),
                                         with: .color(.white.opacity(1 - age / 0.18)))
            }
            if record && age < 1.3 {
                label("BEST", at: CGPoint(x: center.x, y: max(8, center.y - reach - 9)), in: &context, size: 8, weight: .heavy,
                      color: gold.opacity(min(1, (1.3 - age) * 3)))
            }
        }
        if bursts.isEmpty && snapshot.flight == nil {
            label("Each bounce launches a firework", at: CGPoint(x: size.width / 2, y: size.height / 2), in: &context,
                  size: 9, weight: .medium, color: .white.opacity(0.55))
        }
    }

    // MARK: Sky Meter: the ball climbs against a BEST line set by your highest bounce.

    private func skyMeter(_ context: inout GraphicsContext, _ size: CGSize) {
        let ground = size.height - 8, top: CGFloat = 12
        func y(_ lift: Double) -> CGFloat { ground - CGFloat(min(1.08, lift) / 1.08) * (ground - top) }
        for i in 0...10 {
            let ty = ground - CGFloat(i) / 10 * (ground - top) / 1.08
            line(&context, from: CGPoint(x: 8, y: ty), to: CGPoint(x: i % 5 == 0 ? 18 : 13, y: ty), color: .white.opacity(0.35), width: 0.8)
        }
        line(&context, from: CGPoint(x: 0, y: ground), to: CGPoint(x: size.width, y: ground), color: mint.opacity(0.4), width: 1)
        let ballX = size.width * 0.56
        // Earlier bounces trail off to the left as ghosts at their peak height.
        for (k, arc) in snapshot.arcs.suffix(7).reversed().enumerated() {
            let gx = ballX - CGFloat(k + 1) * 26
            guard gx > 26 else { continue }
            let opacity = 0.5 - Double(k) * 0.06
            dot(&context, at: CGPoint(x: gx, y: y(arc.lift)), radius: 3.6, color: ivory.opacity(opacity))
            line(&context, from: CGPoint(x: gx, y: y(arc.lift) + 4), to: CGPoint(x: gx, y: ground), color: ivory.opacity(opacity * 0.25), width: 0.6)
        }
        let live = snapshot.flight?.peak ?? 0
        let pushing = live > snapshot.best + 0.005 && snapshot.best > 0
        let bestLevel = max(snapshot.best, pushing ? live : 0)
        if bestLevel > 0 {
            let by = y(bestLevel), fresh = snapshot.bestAge.map { $0 < 0.9 } ?? false
            var dashed = Path(); dashed.move(to: CGPoint(x: 24, y: by)); dashed.addLine(to: CGPoint(x: size.width - (size.width < 230 ? 20 : 46), y: by))
            if fresh || pushing { glow(context, radius: 3).stroke(dashed, with: .color(gold), lineWidth: 3) }
            context.stroke(dashed, with: .color(gold.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            if size.width < 230 {
                symbol("crown.fill", in: CGRect(x: size.width - 16, y: by - 6, width: 12, height: 9), color: gold, in: &context)
            } else {
                symbol("crown.fill", in: CGRect(x: size.width - 42, y: by - 7, width: 13, height: 10), color: gold, in: &context)
                label(fresh ? "NEW BEST!" : "BEST", at: CGPoint(x: size.width - 27, y: by), in: &context,
                      size: fresh ? 8 : 8.5, weight: .heavy, color: gold, anchor: .leading)
            }
        }
        if let lift = snapshot.lift {
            let by = y(lift)
            if let flight = snapshot.flight, !flight.falling {
                context.stroke(Path { $0.move(to: CGPoint(x: ballX, y: ground)); $0.addLine(to: CGPoint(x: ballX, y: by + 7)) },
                               with: .linearGradient(Gradient(colors: [.clear, lime.opacity(0.7)]),
                                                     startPoint: CGPoint(x: ballX, y: ground), endPoint: CGPoint(x: ballX, y: by)),
                               lineWidth: 3)
            }
            sphere(&context, CGRect(x: ballX - 7, y: by - 7, width: 14, height: 14))
            if snapshot.best > 0.05 {
                let share = Int((lift / snapshot.best * 100).rounded())
                label("\(share)%", at: CGPoint(x: ballX + 12, y: by), in: &context, size: 10, weight: .bold,
                      color: share >= 100 ? gold : lime, anchor: .leading, design: .rounded)
            }
        } else {
            label("Ball out of view", at: CGPoint(x: ballX, y: ground - 12), in: &context, size: 8.5, weight: .medium, color: .white.opacity(0.5))
        }
    }

    // MARK: Combo: steady touches fill the bar; every ten raises the multiplier. A lost rhythm breaks it.

    private func combo(_ context: inout GraphicsContext, _ size: CGSize) {
        let combo = snapshot.combo
        let palette = [lime, mint, gold, coral, Color(red: 0.4, green: 0.82, blue: 1)]
        let tint = palette[(combo.level - 1) % palette.count]
        let age = lastTouchAge ?? 9
        let levelUp = combo.fill == 0 && combo.streak >= 10 && age < 0.6
        let pop = !reduceMotion && age < 0.3 && combo.streak > 0 ? 1 + 0.25 * (1 - age / 0.3) : 1
        let compact = size.width < 230
        let multiplierCenter = compact ? CGPoint(x: 20, y: 13) : CGPoint(x: 38, y: size.height * 0.45)
        let bigSize: CGFloat = compact ? 20 : 34
        if combo.streak > 0 {
            if levelUp { glow(context, radius: 8).fill(Path(ellipseIn: CGRect(x: 8, y: multiplierCenter.y - 24, width: 60, height: 48)), with: .color(tint.opacity(0.6))) }
            var big = context
            big.translateBy(x: multiplierCenter.x, y: multiplierCenter.y); big.scaleBy(x: pop, y: pop)
            big.draw(Text("x\(combo.level)").font(.system(size: bigSize, weight: .black, design: .rounded)).foregroundStyle(tint), at: .zero)
        } else {
            label("x1", at: multiplierCenter, in: &context, size: bigSize, weight: .black, color: .white.opacity(0.25), design: .rounded)
        }
        let barLeft: CGFloat = compact ? 4 : 84, barRight = size.width - (compact ? 4 : 6)
        let barTop = compact ? size.height * 0.42 : size.height * 0.3, barHeight: CGFloat = compact ? 13 : 20
        let slot = (barRight - barLeft) / 10
        let broken = combo.brokenAge
        for i in 0..<10 {
            var rect = CGRect(x: barLeft + CGFloat(i) * slot + 1.5, y: barTop, width: slot - 3, height: barHeight)
            let filled = i < combo.fill || (levelUp && age < 0.25)
            if let broken, i < 10 {
                // The bar shatters and falls.
                let fall = CGFloat(broken * broken) * (60 + CGFloat(i * 7 % 13) * 3)
                rect = rect.offsetBy(dx: CGFloat((i % 3) - 1) * CGFloat(broken) * 10, dy: fall)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(coral.opacity(max(0, 0.8 - broken))))
                continue
            }
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            if filled {
                let newest = i == combo.fill - 1 && age < 0.3
                if newest { glow(context, radius: 4).fill(shape, with: .color(tint)) }
                context.fill(shape, with: .linearGradient(Gradient(colors: [tint, tint.opacity(0.7)]),
                                                          startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
            } else {
                context.fill(shape, with: .color(.black.opacity(0.3)))
                context.stroke(shape, with: .color(.white.opacity(0.22)), lineWidth: 0.8)
            }
        }
        let captionY = barTop + barHeight + (compact ? 9 : 13)
        let captionSize: CGFloat = compact ? 7.5 : 9.5
        if let broken {
            var shaking = context
            shaking.translateBy(x: CGFloat(sin(broken * 60)) * 3 * CGFloat(max(0, 1 - broken * 2)), y: 0)
            shaking.draw(Text("COMBO LOST").font(.system(size: captionSize + 1.5, weight: .heavy)).foregroundStyle(coral),
                         at: CGPoint(x: barLeft, y: captionY), anchor: .leading)
        } else if levelUp {
            label("LEVEL UP!", at: CGPoint(x: barLeft, y: captionY), in: &context, size: captionSize + 1.5, weight: .heavy, color: tint, anchor: .leading)
        } else {
            label(combo.streak > 0 ? "STREAK \(combo.streak)" : compact ? "Steady rhythm" : "Keep a steady rhythm", at: CGPoint(x: barLeft, y: captionY),
                  in: &context, size: captionSize, weight: .semibold, color: .white.opacity(0.8), anchor: .leading)
        }
        label("BEST \(combo.best)", at: CGPoint(x: barRight, y: captionY), in: &context, size: captionSize, weight: .semibold,
              color: .white.opacity(0.55), anchor: .trailing)
    }

    // MARK: Metronome: the pendulum reaches each side exactly on a touch, so it swings at your tempo.

    private func metronome(_ context: inout GraphicsContext, _ size: CGSize) {
        let compact = size.width < 230
        let baseY = size.height - 3, bodyHeight = size.height - 6
        let cx: CGFloat = compact ? 28 : 70, half: CGFloat = compact ? 22 : 30, crown: CGFloat = compact ? 8 : 11
        var body = Path()
        body.move(to: CGPoint(x: cx - half, y: baseY)); body.addLine(to: CGPoint(x: cx + half, y: baseY))
        body.addLine(to: CGPoint(x: cx + crown, y: baseY - bodyHeight)); body.addLine(to: CGPoint(x: cx - crown, y: baseY - bodyHeight))
        body.closeSubpath()
        context.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.2), Color(white: 0.09)]),
                                                 startPoint: CGPoint(x: cx - half, y: 0), endPoint: CGPoint(x: cx + half, y: 0)))
        context.stroke(body, with: .color(mint.opacity(0.35)), lineWidth: 0.8)
        for i in 0..<7 {
            let ty = baseY - 16 - CGFloat(i) * (bodyHeight - 26) / 7
            line(&context, from: CGPoint(x: cx - 3, y: ty), to: CGPoint(x: cx + 3, y: ty), color: .white.opacity(0.25), width: 0.6)
        }
        let maximum = 0.46
        var angle = 0.0
        if let last = snapshot.played.last {
            let interval = (snapshot.nextTouch ?? last + (snapshot.rhythm.interval ?? 0.8)) - last
            let p = (now - last) / max(0.15, interval)
            let side: Double = snapshot.played.count % 2 == 0 ? 1 : -1
            angle = p <= 1 ? side * maximum * cos(.pi * p)
                : -side * maximum * cos(.pi * (p - 1)) * exp(-(p - 1) * 1.6)
        }
        let pivot = CGPoint(x: cx, y: baseY - 12), arm = bodyHeight - 4
        let tip = CGPoint(x: pivot.x + CGFloat(sin(angle)) * arm, y: pivot.y - CGFloat(cos(angle)) * arm)
        line(&context, from: pivot, to: tip, color: ivory, width: 2)
        // The weight sits higher for a slower tempo, like a real metronome.
        let tempo = snapshot.rhythm.perMinute ?? 100
        let position = CGFloat(min(0.85, max(0.35, 1.25 - tempo / 160)))
        let weight = CGPoint(x: pivot.x + (tip.x - pivot.x) * position, y: pivot.y + (tip.y - pivot.y) * position)
        var block = context
        block.translateBy(x: weight.x, y: weight.y); block.rotate(by: .radians(angle))
        block.fill(Path(roundedRect: CGRect(x: -6, y: -4, width: 12, height: 8), cornerRadius: 2), with: .color(lime))
        dot(&context, at: pivot, radius: 2.4, color: mint)
        if let age = lastTouchAge, age < 0.2 {
            glow(context, radius: 4).fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)),
                                          with: .color(lime.opacity(1 - age / 0.2)))
            label("tick", at: CGPoint(x: tip.x + (angle > 0 ? 15 : -15), y: max(9, tip.y + 6)), in: &context, size: 8, weight: .bold,
                  color: lime.opacity(1 - age / 0.2))
        }
        let rate = snapshot.rhythm.perMinute
        let marking = rate.map { r in r < 66 ? "Largo" : r < 76 ? "Adagio" : r < 108 ? "Andante" : r < 120 ? "Moderato" : r < 156 ? "Allegro" : "Presto" }
        if compact {
            let textX = cx + 30
            label(rate.map { String(format: "%.0f", $0) } ?? "—", at: CGPoint(x: textX, y: size.height * 0.3), in: &context,
                  size: 22, weight: .bold, anchor: .leading, design: .rounded)
            label(marking ?? "—", at: CGPoint(x: textX, y: size.height * 0.66), in: &context, size: 12, weight: .semibold,
                  color: lime, anchor: .leading, design: .serif)
        } else {
            let textX = cx + 52
            label(rate.map { String(format: "%.0f", $0) } ?? "—", at: CGPoint(x: textX, y: size.height * 0.36), in: &context,
                  size: 30, weight: .bold, anchor: .leading, design: .rounded)
            label("TOUCHES / MIN", at: CGPoint(x: textX + 2, y: size.height * 0.64), in: &context, size: 7.5, weight: .medium,
                  color: .white.opacity(0.55), anchor: .leading)
            label(marking ?? "Waiting for a rhythm", at: CGPoint(x: size.width - 4, y: size.height * 0.36), in: &context,
                  size: marking == nil ? 9 : 17, weight: .semibold, color: marking == nil ? .white.opacity(0.5) : lime, anchor: .trailing,
                  design: .serif)
        }
    }

    // MARK: Rainbow Arcs: every bounce becomes an arc of color; height and rhythm at a glance.

    private func rainbow(_ context: inout GraphicsContext, _ size: CGSize) {
        let window = 6.0, ground = size.height - 6, top: CGFloat = 8
        func x(_ t: Double) -> CGFloat { CGFloat((t - (now - window)) / window) * size.width }
        func rise(_ lift: Double) -> CGFloat { CGFloat(max(0.06, lift)) * (ground - top) }
        func color(_ number: Int) -> Color {
            Color(hue: (Double(number) * 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1)
        }
        line(&context, from: CGPoint(x: 0, y: ground), to: CGPoint(x: size.width, y: ground), color: .white.opacity(0.18), width: 0.6)
        var lit = context
        lit.blendMode = .plusLighter
        for arc in snapshot.arcs where x(arc.end) > 0 {
            var path = Path()
            path.move(to: CGPoint(x: x(arc.start), y: ground))
            // A quadratic peaks halfway to its control point.
            path.addQuadCurve(to: CGPoint(x: x(arc.end), y: ground), control: CGPoint(x: x(arc.apex), y: ground - 2 * rise(arc.lift)))
            let tint = color(arc.number)
            glow(lit, radius: 3).stroke(path, with: .color(tint.opacity(0.55)), lineWidth: 6)
            lit.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            lit.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
        if let flight = snapshot.flight, let lift = snapshot.lift {
            let tint = color(snapshot.played.count)
            let end = CGPoint(x: x(now), y: ground - rise(lift))
            var path = Path()
            path.move(to: CGPoint(x: x(flight.start), y: ground))
            path.addQuadCurve(to: end, control: CGPoint(x: (x(flight.start) + end.x) / 2, y: ground - rise(flight.peak) * 1.6))
            glow(lit, radius: 3).stroke(path, with: .color(tint.opacity(0.55)), lineWidth: 6)
            lit.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            sphere(&context, CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10))
        } else if snapshot.arcs.isEmpty {
            label("Each bounce paints an arc", at: CGPoint(x: size.width / 2, y: size.height / 2), in: &context,
                  size: 9, weight: .medium, color: .white.opacity(0.55))
        }
    }
}
