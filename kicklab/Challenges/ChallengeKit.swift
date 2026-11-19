import SwiftUI

/// Football kit that stands on the challenge path instead of a plain number: a shirt for
/// streaks, a boot for one foot, an agility ladder for footwork, a stopwatch for timed
/// rounds, a corner flag for speed and a cone drill for rounds. Drawn in a 100 × 100 box.
enum KitState { case open, next, done }

struct KitPalette {
    let body: Color, line: Color, ink: Color, accent: Color, accentText: Color, wedge: Color

    init(_ state: KitState, scheme: ColorScheme) {
        let dark = scheme == .dark
        let kitLine = dark ? Color(red: 0.29, green: 0.34, blue: 0.36) : Color(red: 0.71, green: 0.74, blue: 0.68)
        let soft = dark ? Color(red: 0.21, green: 0.27, blue: 0.12) : Color(red: 0.86, green: 0.92, blue: 0.65)
        switch state {
        case .open:
            body = TrainingHomeStyle.panel(scheme); line = kitLine; ink = TrainingHomeStyle.ink(scheme)
            accent = soft; accentText = TrainingHomeStyle.ink(scheme); wedge = TrainingHomeStyle.lime.opacity(0.62)
        case .next:
            body = TrainingHomeStyle.panel(scheme); line = TrainingHomeStyle.accent(scheme); ink = TrainingHomeStyle.ink(scheme)
            accent = TrainingHomeStyle.lime; accentText = TrainingHomeStyle.buttonInk; wedge = TrainingHomeStyle.lime.opacity(0.62)
        case .done:
            body = TrainingHomeStyle.lime; line = Color(red: 0.58, green: 0.74, blue: 0.12); ink = TrainingHomeStyle.buttonInk
            accent = TrainingHomeStyle.buttonInk; accentText = TrainingHomeStyle.lime; wedge = TrainingHomeStyle.buttonInk.opacity(0.14)
        }
    }
}

/// A path drawn in a `box` × `box` grid, scaled to whatever frame it gets.
struct KitShape: Shape {
    let outline: Path
    var box: CGFloat = 100

    func path(in rect: CGRect) -> Path {
        outline.applying(CGAffineTransform(scaleX: rect.width / box, y: rect.height / box)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

extension Path {
    fileprivate mutating func m(_ x: CGFloat, _ y: CGFloat) { move(to: CGPoint(x: x, y: y)) }
    fileprivate mutating func l(_ x: CGFloat, _ y: CGFloat) { addLine(to: CGPoint(x: x, y: y)) }
    fileprivate mutating func q(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
    }
}

extension JuggleChallenge {
    /// Where the ball rests on this challenge's kit, as a fraction of its box.
    var kitTop: CGPoint {
        switch rule {
        case .streak, .beatYourBest, .friend: CGPoint(x: 0.5, y: 0.13)
        case .oneFoot(let side, _): CGPoint(x: side == .left ? 0.54 : 0.46, y: 0.34)
        case .pattern: CGPoint(x: 0.34, y: 0.29)
        case .bestStreak, .sprint, .keepItUp: CGPoint(x: 0.5, y: 0.05)
        case .inTime, .race: CGPoint(x: 0.30, y: 0.10)
        case .aroundTheWorld: CGPoint(x: 0.5, y: 0.33)
        case .series(let rounds):
            CGPoint(x: 0.5, y: (ConeDrillKit.tip(ConeDrillKit.height(rounds[1], of: rounds.max() ?? 1)) - 22) / 100)
        case .steady: CGPoint(x: 0.5, y: (ConeDrillKit.tip(ConeDrillKit.tallest) - 22) / 100)
        }
    }
}

struct ChallengeKitView: View {
    let challenge: JuggleChallenge
    let best: Int
    let state: KitState
    let size: CGFloat
    /// The next challenge's kit moves a little; everything else is still.
    var lively = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = KitPalette(state, scheme: scheme)
        let live = lively && state == .next && !reduceMotion
        ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(.black.opacity(scheme == .dark ? 0.32 : 0.1))
                .frame(width: size * 0.5, height: size * 0.07)
                .position(x: size * 0.5, y: size * 0.94)
            piece(palette, live: live)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func piece(_ palette: KitPalette, live: Bool) -> some View {
        switch challenge.rule {
        case .streak(let target): ShirtKit(number: "\(target)", palette: palette, size: size, live: live)
        case .beatYourBest: ShirtKit(number: "\(best + 1)", palette: palette, size: size, live: live)
        case .friend: ShirtKit(number: "VS", palette: palette, size: size, live: live)
        case .aroundTheWorld(let count): AroundTheWorldKit(count: count, palette: palette, size: size, live: live)
        case .oneFoot(let side, let target): BootKit(count: target, side: side, palette: palette, size: size, live: live)
        case .pattern(let pattern, let repeats): LadderKit(pattern: Array(pattern), repeats: repeats, palette: palette, size: size, live: live)
        case .bestStreak(let s), .sprint(let s), .keepItUp(let s): StopwatchKit(seconds: s, palette: palette, size: size, live: live)
        case .inTime(let target, let seconds): FlagKit(big: "\(target)", small: "IN \(seconds)S", palette: palette, size: size, live: live)
        case .race(let target, _): FlagKit(big: "\(target)", small: "RACE", palette: palette, size: size, live: live)
        case .series(let rounds):
            ConeDrillKit(labels: rounds.map(String.init), heights: rounds.map { ConeDrillKit.height($0, of: rounds.max() ?? 1) },
                         palette: palette, size: size, live: live)
        case .steady(let seconds, _):
            ConeDrillKit(labels: Array(repeating: "\(seconds)s", count: 3), heights: Array(repeating: ConeDrillKit.tallest, count: 3),
                         palette: palette, size: size, live: live)
        }
    }
}

// MARK: - Shared bits

private func kitFont(_ size: CGFloat) -> Font { .custom("DINCondensed-Bold", fixedSize: size) }

/// Text placed by its centre in the 100-unit box.
private struct KitText: View {
    let text: String
    let x: CGFloat, y: CGFloat, size: CGFloat
    let color: Color
    let unit: CGFloat

    init(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: Color, unit: CGFloat) {
        self.text = text; self.x = x; self.y = y; self.size = size; self.color = color; self.unit = unit
    }

    var body: some View {
        Text(verbatim: text)
            .font(kitFont(size * unit))
            .foregroundStyle(color)
            .fixedSize()
            .position(x: x * unit, y: y * unit)
    }
}

private func outline(_ path: Path, _ palette: KitPalette, _ unit: CGFloat, width: CGFloat = 2.6, dashed: Bool = false) -> some View {
    KitShape(outline: path).stroke(palette.line, style: StrokeStyle(lineWidth: width * unit, lineCap: .round, lineJoin: .round,
                                                                      dash: dashed ? [5 * unit, 4 * unit] : []))
}

/// A gentle back-and-forth turn, for the next challenge only.
private struct Sway: ViewModifier {
    let live: Bool
    let anchor: UnitPoint
    let degrees: Double
    let period: Double

    @ViewBuilder func body(content: Content) -> some View {
        if live {
            content.keyframeAnimator(initialValue: 0.0, repeating: true) { view, angle in
                view.rotationEffect(.degrees(angle), anchor: anchor)
            } keyframes: { _ in
                CubicKeyframe(degrees, duration: period / 4)
                CubicKeyframe(-degrees, duration: period / 2)
                CubicKeyframe(0, duration: period / 4)
            }
        } else {
            content
        }
    }
}

// MARK: - Shirt (streaks)

private struct ShirtKit: View {
    let number: String
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    static let shirt = Path { p in
        p.m(36, 14); p.l(24, 19); p.l(10, 33); p.l(19, 45); p.l(27, 39); p.l(27, 86); p.q(50, 91, 73, 86)
        p.l(73, 39); p.l(81, 45); p.l(90, 33); p.l(76, 19); p.l(64, 14); p.q(57, 23, 50, 23); p.q(43, 23, 36, 14)
        p.closeSubpath()
    }
    static let cuffs = Path { p in p.m(15, 31.5); p.l(21.5, 40); p.m(85, 31.5); p.l(78.5, 40) }
    static let collar = Path { p in p.m(36, 14); p.q(43, 23, 50, 23); p.q(57, 23, 64, 14) }

    var body: some View {
        let u = size / 100
        ZStack(alignment: .topLeading) {
            KitShape(outline: Self.shirt).fill(palette.body)
            outline(Self.shirt, palette, u)
            KitShape(outline: Self.cuffs).stroke(palette.accent, style: StrokeStyle(lineWidth: 4 * u, lineCap: .round))
            outline(Self.collar, palette, u, width: 3.2)
            KitText(number, x: 50, y: 60, size: number.count > 2 ? 26 : 32, color: palette.ink, unit: u)
        }
        .frame(width: size, height: size)
        .modifier(Sway(live: live, anchor: UnitPoint(x: 0.5, y: 0.14), degrees: 3, period: 2.6))
    }
}

// MARK: - Boot (one foot)

/// A football boot from the side: low collar, laced instep, pointed toe and studs. The foot
/// letter sits on the heel patch and the count on the side. Left boots face the other way.
private struct BootKit: View {
    let count: Int
    let side: JuggleChallenge.Side
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    static let upper = Path { p in
        p.move(to: CGPoint(x: 12, y: 78))
        p.addQuadCurve(to: CGPoint(x: 7.5, y: 70), control: CGPoint(x: 7, y: 77))
        p.addLine(to: CGPoint(x: 9, y: 52))
        p.addQuadCurve(to: CGPoint(x: 17, y: 44), control: CGPoint(x: 10, y: 45))
        p.addQuadCurve(to: CGPoint(x: 34, y: 44), control: CGPoint(x: 26, y: 43))
        p.addQuadCurve(to: CGPoint(x: 44, y: 35), control: CGPoint(x: 37, y: 37))
        p.addQuadCurve(to: CGPoint(x: 49, y: 37), control: CGPoint(x: 47, y: 34.5))
        p.addQuadCurve(to: CGPoint(x: 72, y: 51), control: CGPoint(x: 60, y: 46))
        p.addQuadCurve(to: CGPoint(x: 94, y: 66), control: CGPoint(x: 88, y: 56))
        p.addQuadCurve(to: CGPoint(x: 95, y: 75), control: CGPoint(x: 97, y: 71))
        p.addQuadCurve(to: CGPoint(x: 88, y: 78), control: CGPoint(x: 93, y: 78))
        p.closeSubpath()
    }
    static let heelPatch = Path { p in
        p.move(to: CGPoint(x: 9.2, y: 52))
        p.addQuadCurve(to: CGPoint(x: 17, y: 44.6), control: CGPoint(x: 10.4, y: 45.6))
        p.addLine(to: CGPoint(x: 21, y: 44.4))
        p.addLine(to: CGPoint(x: 21, y: 74))
        p.addLine(to: CGPoint(x: 8.2, y: 74))
        p.closeSubpath()
    }
    static let toeCap = Path { p in
        p.move(to: CGPoint(x: 80, y: 57))
        p.addQuadCurve(to: CGPoint(x: 78, y: 78), control: CGPoint(x: 74, y: 68))
        p.addLine(to: CGPoint(x: 88, y: 78))
        p.addQuadCurve(to: CGPoint(x: 95, y: 75), control: CGPoint(x: 93, y: 78))
        p.addQuadCurve(to: CGPoint(x: 94, y: 66), control: CGPoint(x: 97, y: 71))
        p.addQuadCurve(to: CGPoint(x: 80, y: 57), control: CGPoint(x: 89, y: 59))
        p.closeSubpath()
    }
    static let sole = Path(roundedRect: CGRect(x: 8, y: 77, width: 87, height: 4.5), cornerRadius: 2.2)
    static let studs = Path { p in
        for x: CGFloat in [15, 25, 55, 67, 79, 88] {
            p.move(to: CGPoint(x: x - 2.6, y: 81)); p.addLine(to: CGPoint(x: x + 2.6, y: 81))
            p.addLine(to: CGPoint(x: x + 1.6, y: 87)); p.addLine(to: CGPoint(x: x - 1.6, y: 87)); p.closeSubpath()
        }
    }
    static let laces = Path { p in
        for (x, y) in [(53.4, 40.4), (58.0, 43.6), (62.6, 46.4), (67.2, 48.8)] as [(CGFloat, CGFloat)] {
            p.move(to: CGPoint(x: x + 1, y: y + 0.6)); p.addLine(to: CGPoint(x: x - 2.8, y: y + 6))
        }
    }

    var body: some View {
        let u = size / 100, left = side == .left, weaker = side == .weaker
        let flip: (CGFloat) -> CGFloat = { left ? 100 - $0 : $0 }
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                KitShape(outline: Self.studs).fill(palette.line)
                KitShape(outline: Self.sole).fill(palette.line)
                KitShape(outline: Self.upper).fill(palette.body)
                KitShape(outline: Self.toeCap).fill(palette.accent.opacity(0.55))
                Group {
                    if weaker {
                        KitShape(outline: Self.heelPatch)
                            .stroke(palette.line, style: StrokeStyle(lineWidth: 2 * u, lineJoin: .round, dash: [3.5 * u, 3 * u]))
                    } else {
                        KitShape(outline: Self.heelPatch).fill(palette.accent)
                    }
                }
                outline(Self.upper, palette, u, dashed: weaker)
                KitShape(outline: Self.laces).stroke(palette.ink.opacity(0.75), style: StrokeStyle(lineWidth: 2 * u, lineCap: .round))
            }
            .frame(width: size, height: size)
            .scaleEffect(x: left ? -1 : 1, y: 1)
            KitText(weaker ? "W" : left ? "L" : "R", x: flip(14.8), y: 59, size: 13,
                    color: weaker ? palette.ink : palette.accentText, unit: u)
            KitText("\(count)", x: flip(36), y: 62, size: 22, color: palette.ink, unit: u)
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: 0.0, repeating: live) { view, angle in
            view.rotationEffect(.degrees(left ? -angle : angle), anchor: UnitPoint(x: left ? 0.9 : 0.1, y: 0.8))
        } keyframes: { _ in
            LinearKeyframe(0, duration: 0.7)
            CubicKeyframe(live ? -9 : 0, duration: 0.2)
            CubicKeyframe(live ? 1.5 : 0, duration: 0.2)
            CubicKeyframe(0, duration: 0.2)
        }
    }
}

// MARK: - Agility ladder (footwork)

private struct LadderKit: View {
    let pattern: [Character]
    let repeats: Int
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    var body: some View {
        let u = size / 100, k = CGFloat(pattern.count), w = 84 / k
        let rails = Path { p in
            p.m(8, 36); p.l(92, 36); p.m(8, 64); p.l(92, 64)
            for i in 0...pattern.count { p.m(8 + CGFloat(i) * w, 36); p.l(8 + CGFloat(i) * w, 64) }
        }
        let plate = Path(roundedRect: CGRect(x: 3, y: 28, width: 94, height: 44), cornerRadius: 10)
        ZStack(alignment: .topLeading) {
            KitShape(outline: plate).fill(palette.body)
            outline(plate, palette, u)
            outline(rails, palette, u)
            TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                let beat = live ? Int(timeline.date.timeIntervalSinceReferenceDate / 0.2) % (pattern.count + 4) : -1
                ZStack(alignment: .topLeading) {
                    ForEach(Array(pattern.enumerated()), id: \.offset) { index, letter in
                        let centre = 8 + (CGFloat(index) + 0.5) * w, boxWidth = max(6, w - 6)
                        let box = Path(roundedRect: CGRect(x: centre - boxWidth / 2, y: 40, width: boxWidth, height: 20), cornerRadius: 4)
                        Group {
                            if letter == "R" { KitShape(outline: box).fill(palette.accent) } else { outline(box, palette, u) }
                        }
                        .opacity(beat == index ? 0.25 : 1)
                        KitText(String(letter), x: centre, y: 50.5, size: 13,
                                color: letter == "R" ? palette.accentText : palette.ink, unit: u)
                            .opacity(beat == index ? 0.4 : 1)
                    }
                }
                .frame(width: size, height: size)
                .animation(.easeInOut(duration: 0.15), value: beat)
            }
            KitShape(outline: Path(roundedRect: CGRect(x: 64, y: 8, width: 30, height: 17), cornerRadius: 8.5)).fill(palette.accent)
            KitText("×\(repeats)", x: 79, y: 17, size: 12, color: palette.accentText, unit: u)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Stopwatch (timed)

private struct StopwatchKit: View {
    let seconds: Int
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    var body: some View {
        let u = size / 100, centre = CGPoint(x: 50, y: 56), fraction = min(1, CGFloat(seconds) / 60)
        let crown = Path(roundedRect: CGRect(x: 44, y: 5, width: 12, height: 7), cornerRadius: 2.5)
        let stem = Path { p in p.m(50, 12); p.l(50, 19) }
        let button = Path(roundedRect: CGRect(x: 71, y: 13, width: 10, height: 6), cornerRadius: 2.5)
            .applying(CGAffineTransform(translationX: -76, y: -16).concatenating(.init(rotationAngle: .pi * 40 / 180)).concatenating(.init(translationX: 76, y: 16)))
        let face = Path(ellipseIn: CGRect(x: 14, y: 20, width: 72, height: 72))
        let wedge = Path { p in
            if fraction >= 1 { p.addEllipse(in: CGRect(x: 23, y: 29, width: 54, height: 54)) } else {
                p.move(to: centre); p.l(50, 29)
                p.addArc(center: centre, radius: 27, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(fraction)), clockwise: false)
                p.closeSubpath()
            }
        }
        let ticks = Path { p in
            for i in 0..<12 {
                let a = CGFloat(i) / 12 * 2 * .pi
                p.m(50 + 30 * sin(a), 56 - 30 * cos(a)); p.l(50 + 33 * sin(a), 56 - 33 * cos(a))
            }
        }
        ZStack(alignment: .topLeading) {
            KitShape(outline: crown).fill(palette.body); outline(crown, palette, u)
            outline(stem, palette, u)
            KitShape(outline: button).fill(palette.body); outline(button, palette, u)
            KitShape(outline: face).fill(palette.body); outline(face, palette, u, width: 3)
            KitShape(outline: wedge).fill(palette.wedge)
            KitShape(outline: ticks).stroke(palette.line, style: StrokeStyle(lineWidth: 2 * u, lineCap: .round))
            if live {
                // A lime dot runs round the rim instead of a hand, so the number stays clear.
                Circle()
                    .fill(TrainingHomeStyle.lime)
                    .frame(width: 7 * u, height: 7 * u)
                    .shadow(color: TrainingHomeStyle.lime.opacity(0.9), radius: 3 * u)
                    .offset(y: -31.5 * u)
                    .position(x: 50 * u, y: 56 * u)
                    .keyframeAnimator(initialValue: 0.0, repeating: true) { view, angle in
                        view.rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: 0.56))
                    } keyframes: { _ in
                        LinearKeyframe(360, duration: 3)
                    }
            }
            KitText("\(seconds)", x: 50, y: 55.5, size: 24, color: palette.ink, unit: u)
            KitText("SEC", x: 50, y: 71.5, size: 7, color: palette.ink, unit: u)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Corner flag (speed)

private struct FlagKit: View {
    let big: String
    let small: String
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    static let flag = Path { p in
        p.m(31.5, 13); p.q(47, 8, 61, 14); p.q(75, 20, 90, 14); p.l(90, 50); p.q(75, 56, 61, 50); p.q(47, 44, 31.5, 49); p.closeSubpath()
    }

    var body: some View {
        let u = size / 100
        ZStack(alignment: .topLeading) {
            KitShape(outline: Path(ellipseIn: CGRect(x: 20, y: 88, width: 20, height: 6))).fill(palette.line)
            KitShape(outline: Path { p in p.m(30, 90); p.l(30, 11) })
                .stroke(palette.line, style: StrokeStyle(lineWidth: 3.6 * u, lineCap: .round))
            ZStack(alignment: .topLeading) {
                KitShape(outline: Self.flag).fill(palette.body)
                outline(Self.flag, palette, u)
                KitText(big, x: 61, y: 30.5, size: big.count > 2 ? 16 : 20, color: palette.ink, unit: u)
                KitText(small, x: 61, y: 43.5, size: 7.5, color: palette.ink, unit: u)
            }
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: 0.0, repeating: live) { view, angle in
                view.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: UnitPoint(x: 0.31, y: 0.3), perspective: 0.5)
            } keyframes: { _ in
                CubicKeyframe(live ? 22 : 0, duration: 0.55)
                CubicKeyframe(live ? -12 : 0, duration: 0.6)
                CubicKeyframe(0, duration: 0.45)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Cone drill (rounds)

/// Three training cones, one per round. Bigger round goals stand on taller cones, and each
/// goal sits just above its cone. On the next challenge the cones hop one after another.
struct ConeDrillKit: View {
    let labels: [String]
    let heights: [CGFloat]
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    nonisolated static let tallest: CGFloat = 54
    nonisolated static func height(_ value: Int, of largest: Int) -> CGFloat { 32 + 22 * CGFloat(value) / CGFloat(max(1, largest)) }
    /// The y of a cone's tip in the 100-unit box.
    nonisolated static func tip(_ height: CGFloat) -> CGFloat { 82 - height - 2 }

    private static let centres: [CGFloat] = [18, 50, 82]

    private static func cone(_ x: CGFloat, _ h: CGFloat) -> (body: Path, band: Path, base: Path) {
        let foot: CGFloat = 82, top = foot - h
        let body = Path { p in
            p.move(to: CGPoint(x: x - 12, y: foot))
            p.addQuadCurve(to: CGPoint(x: x - 3, y: top + 2), control: CGPoint(x: x - 8.5, y: top + h * 0.45))
            p.addQuadCurve(to: CGPoint(x: x + 3, y: top + 2), control: CGPoint(x: x, y: top - 2))
            p.addQuadCurve(to: CGPoint(x: x + 12, y: foot), control: CGPoint(x: x + 8.5, y: top + h * 0.45))
            p.closeSubpath()
        }
        // The stripe runs across the cone at about a third of its height.
        func halfWidth(_ y: CGFloat) -> CGFloat { 3 + 9 * pow((y - top) / h, 0.8) }
        let y1 = top + h * 0.38, y2 = top + h * 0.56
        let band = Path { p in
            p.move(to: CGPoint(x: x - halfWidth(y1), y: y1)); p.addLine(to: CGPoint(x: x + halfWidth(y1), y: y1))
            p.addLine(to: CGPoint(x: x + halfWidth(y2), y: y2)); p.addLine(to: CGPoint(x: x - halfWidth(y2), y: y2))
            p.closeSubpath()
        }
        let base = Path(roundedRect: CGRect(x: x - 15, y: foot - 1, width: 30, height: 6), cornerRadius: 2)
        return (body, band, base)
    }

    var body: some View {
        let u = size / 100
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(0..<min(3, labels.count), id: \.self) { index in
                    let x = Self.centres[index], h = heights[index]
                    let parts = Self.cone(x, h)
                    let phase = (t / 1.8 - Double(index) * 0.12).truncatingRemainder(dividingBy: 1)
                    let hopping = live && phase >= 0 && phase < 0.16
                    let lift: CGFloat = hopping ? -6 * CGFloat(sin(phase / 0.16 * .pi)) : 0
                    ZStack(alignment: .topLeading) {
                        KitShape(outline: parts.base).fill(palette.line)
                        KitShape(outline: parts.body).fill(palette.body)
                        outline(parts.body, palette, u)
                        KitShape(outline: parts.band).fill(hopping ? TrainingHomeStyle.lime : palette.accent)
                        KitText(labels[index], x: x, y: Self.tip(h) - 9, size: labels[index].count > 2 ? 13 : 16,
                                color: palette.ink, unit: u)
                    }
                    .frame(width: size, height: size)
                    .offset(y: lift * u)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Around the world (tricks)

/// A ball with a lime orbit round it. On the next challenge a foot dot travels the orbit,
/// passing behind the ball and in front of it, the way the trick goes.
private struct AroundTheWorldKit: View {
    let count: Int
    let palette: KitPalette
    let size: CGFloat
    let live: Bool

    private static let centre = CGPoint(x: 50, y: 55)
    private static let tilt = -0.32

    /// A point on the orbit; `front` is true on the half that passes in front of the ball.
    private static func orbit(_ angle: Double) -> (point: CGPoint, front: Bool) {
        let x = 40 * cos(angle), y = 13 * sin(angle)
        let rx = x * cos(tilt) - y * sin(tilt), ry = x * sin(tilt) + y * cos(tilt)
        return (CGPoint(x: centre.x + rx, y: centre.y + ry), sin(angle) > 0)
    }

    private static func ring(from: Double, to: Double) -> Path {
        Path { p in
            let steps = 40
            for i in 0...steps {
                let point = orbit(from + (to - from) * Double(i) / Double(steps)).point
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
        }
    }

    private static let ball = Path(ellipseIn: CGRect(x: 30, y: 35, width: 40, height: 40))
    private static let panels = Path { p in
        // A centre pentagon and seams out to the edge, like a classic ball.
        let corners = (0..<5).map { i -> CGPoint in
            let a = -Double.pi / 2 + Double(i) * 2 * .pi / 5
            return CGPoint(x: 50 + 7.5 * cos(a), y: 55 + 7.5 * sin(a))
        }
        p.addLines(corners); p.closeSubpath()
        for corner in corners {
            let dx = corner.x - 50, dy = corner.y - 55
            p.move(to: corner); p.addLine(to: CGPoint(x: 50 + dx * 2.55, y: 55 + dy * 2.55))
        }
    }
    private static let pentagon = Path { p in
        let corners = (0..<5).map { i -> CGPoint in
            let a = -Double.pi / 2 + Double(i) * 2 * .pi / 5
            return CGPoint(x: 50 + 7.5 * cos(a), y: 55 + 7.5 * sin(a))
        }
        p.addLines(corners); p.closeSubpath()
    }

    var body: some View {
        let u = size / 100
        let ringStyle = StrokeStyle(lineWidth: 3 * u, lineCap: .round, dash: [0.1, 6 * u])
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { timeline in
            let angle = live ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 2 * .pi : 0.25
            let foot = Self.orbit(angle)
            ZStack(alignment: .topLeading) {
                KitShape(outline: Self.ring(from: .pi, to: 2 * .pi)).stroke(TrainingHomeStyle.lime.opacity(0.9), style: ringStyle)
                if !foot.front { footDot(at: foot.point, u: u) }
                KitShape(outline: Self.ball).fill(palette.body)
                KitShape(outline: Self.panels).stroke(palette.line, style: StrokeStyle(lineWidth: 1.6 * u, lineJoin: .round))
                KitShape(outline: Self.pentagon).fill(palette.ink.opacity(0.85))
                outline(Self.ball, palette, u)
                KitShape(outline: Self.ring(from: 0, to: .pi)).stroke(TrainingHomeStyle.lime, style: ringStyle)
                if foot.front { footDot(at: foot.point, u: u) }
                KitShape(outline: Path(roundedRect: CGRect(x: 66, y: 9, width: 28, height: 17), cornerRadius: 8.5)).fill(palette.accent)
                KitText(count == 1 ? "1ST" : "×\(count)", x: 80, y: 17.5, size: 12, color: palette.accentText, unit: u)
            }
            .frame(width: size, height: size)
        }
    }

    private func footDot(at point: CGPoint, u: CGFloat) -> some View {
        Circle()
            .fill(TrainingHomeStyle.lime)
            .overlay(Circle().stroke(palette.line, lineWidth: 1.6 * u))
            .frame(width: 10 * u, height: 10 * u)
            .shadow(color: TrainingHomeStyle.lime.opacity(live ? 0.9 : 0), radius: 4 * u)
            .position(x: point.x * u, y: point.y * u)
    }
}

// MARK: - Group glyphs (24 × 24)

struct ChallengeGroupGlyph: View {
    let group: JuggleChallenge.Group

    private var path: Path {
        switch group {
        case .streaks, .friends:
            Path { p in
                p.m(8.5, 4); p.l(5, 5.6); p.l(2, 9); p.l(4.6, 11.6); p.l(6.6, 10.2); p.l(6.6, 20); p.l(17.4, 20); p.l(17.4, 10.2)
                p.l(19.4, 11.6); p.l(22, 9); p.l(19, 5.6); p.l(15.5, 4); p.q(14, 6.3, 12, 6.3); p.q(10, 6.3, 8.5, 4); p.closeSubpath()
            }
        case .tricks:
            Path { p in
                p.addEllipse(in: CGRect(x: 7, y: 7, width: 10, height: 10))
                p.addPath(Path(ellipseIn: CGRect(x: 1.5, y: 8.5, width: 21, height: 7))
                    .applying(CGAffineTransform(translationX: -12, y: -12).concatenating(.init(rotationAngle: -0.32)).concatenating(.init(translationX: 12, y: 12))))
            }
        case .oneFoot:
            Path { p in
                p.m(3, 16.5); p.l(3, 13); p.q(3, 11.4, 5, 11.2); p.l(9.4, 10.4); p.q(10.4, 6.8, 13, 6.4); p.l(14.8, 6.4); p.q(16, 6.4, 16, 7.8)
                p.l(16, 10.4); p.q(19, 11.2, 21, 12.8); p.q(22, 13.8, 22, 15.2); p.l(22, 16.5); p.q(22, 18, 20.5, 18); p.l(4.5, 18)
                p.q(3, 18, 3, 16.5); p.closeSubpath()
            }
        case .footwork:
            Path { p in
                p.m(3, 8); p.l(21, 8); p.m(3, 16); p.l(21, 16)
                for x: CGFloat in [3, 9, 15, 21] { p.m(x, 8); p.l(x, 16) }
            }
        case .timed:
            Path { p in
                p.addEllipse(in: CGRect(x: 4.5, y: 6, width: 15, height: 15))
                p.m(12, 13.5); p.l(12, 9.6); p.m(9.5, 2.8); p.l(14.5, 2.8); p.m(12, 2.8); p.l(12, 6)
            }
        case .speed:
            Path { p in
                p.m(6, 21); p.l(6, 3); p.m(6.5, 4); p.q(11, 2.5, 14, 4.5); p.q(17, 6.5, 20, 5); p.l(20, 12)
                p.q(17, 13.5, 14, 11.5); p.q(11, 9.5, 6.5, 11)
            }
        case .rounds:
            Path { p in
                p.m(3, 20); p.l(5.6, 12); p.l(8.2, 20); p.closeSubpath()
                p.m(9.4, 20); p.l(12, 7.5); p.l(14.6, 20); p.closeSubpath()
                p.m(15.8, 20); p.l(18.4, 14); p.l(21, 20); p.closeSubpath()
            }
        }
    }

    var body: some View {
        KitShape(outline: path, box: 24)
            .stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
    }
}
