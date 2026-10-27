import SwiftUI

/// Warm clubhouse paper in light mode, graphite in dark; the pennant colours stay the same.
enum LeaderboardStyle {
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.063, green: 0.078, blue: 0.075) : Color(red: 0.945, green: 0.937, blue: 0.906)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.09, green: 0.11, blue: 0.106) : Color(red: 0.984, green: 0.98, blue: 0.96)
    }
    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color(red: 0.87, green: 0.855, blue: 0.81)
    }
    static func olive(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.62, green: 0.75, blue: 0.27) : Color(red: 0.29, green: 0.4, blue: 0.137)
    }
    static let lime = TrainingHomeStyle.lime
    static let limeDeep = Color(red: 0.66, green: 0.79, blue: 0.24)
    static let silver = Color(red: 0.9, green: 0.91, blue: 0.895)
    static let silverDeep = Color(red: 0.69, green: 0.71, blue: 0.69)
    static let bronze = Color(red: 0.88, green: 0.62, blue: 0.42)
    static let bronzeDeep = Color(red: 0.66, green: 0.41, blue: 0.25)
    static let gold = Color(red: 0.8, green: 0.66, blue: 0.32)
    /// Dark ink for the lime, silver and bronze surfaces.
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.06)
    static func number(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .title) }

    /// "st", "nd", "rd" or "th" after a place.
    /// The place as the app's language writes it: 1st, 1., 1.º, 1er.
    static func ordinalPlace(_ place: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: place as NSNumber) ?? "\(place)"
    }

    /// Only the mark after the number, drawn smaller beside it.
    static func ordinal(_ place: Int) -> String {
        String(ordinalPlace(place).drop(while: \.isNumber))
    }
}

/// A hanging pennant with a V-cut tip.
struct PennantShape: InsettableShape {
    var notch: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - notch))
        path.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - notch))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> PennantShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// A player's picture in a ringed badge, or their placeholder.
struct LeaderboardMedallion: View {
    let entry: LeaderboardEntry
    let size: CGFloat
    var ring: Color
    var ringWidth: CGFloat = 3

    var body: some View {
        ZStack {
            PlayerAvatar(name: entry.name, isYou: entry.isYou, size: size, remoteURL: entry.photo)
            Circle().strokeBorder(ring, lineWidth: ringWidth)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

/// The Juggle Dude ball from the app icon: white, with one lime and two ink seams
/// sweeping in from the rim round an open centre. Its seams show every turn.
struct LeaderboardBall: View {
    let size: CGFloat

    private static let seamLime = Color(red: 0.62, green: 0.85, blue: 0.12)

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.white, Color(white: 0.9)], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: size * 0.7))
            BallSeam(from: -96, to: -186, depth: 0.42, thickness: 0.2).fill(LeaderboardStyle.ink)
            BallSeam(from: -80, to: 26, depth: 0.36, thickness: 0.21).fill(Self.seamLime)
            BallSeam(from: 36, to: 110, depth: 0.52, thickness: 0.19).fill(LeaderboardStyle.ink)
            // Shade the far side, so the seams wrap round a sphere.
            Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.16)], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: size * 0.2, endRadius: size * 0.78))
            Circle().strokeBorder(.black.opacity(0.14), lineWidth: max(0.5, size * 0.015))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.25), radius: size * 0.08, y: size * 0.06)
        .accessibilityHidden(true)
    }
}

/// One seam: a crescent from one point on the rim to another, bowed in toward the
/// centre. Angles run clockwise from three o'clock; distances are in radii.
private struct BallSeam: Shape {
    let from: Double
    let to: Double
    /// How far the seam's middle sits from the centre.
    let depth: Double
    let thickness: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ degrees: Double, _ distance: Double) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + cos(angle) * distance * radius, y: center.y + sin(angle) * distance * radius)
        }
        // A quadratic passes halfway between its chord's midpoint and its control.
        let middle = (from + to) / 2
        let chord = 1.04 * cos(abs(to - from) / 2 * .pi / 180)
        func control(_ distance: Double) -> CGPoint { point(middle, 2 * distance - chord) }
        var path = Path()
        path.move(to: point(from, 1.04))
        path.addQuadCurve(to: point(to, 1.04), control: control(depth + thickness / 2))
        path.addQuadCurve(to: point(from, 1.04), control: control(depth - thickness / 2))
        path.closeSubpath()
        return path
    }
}

private enum PennantMetrics {
    /// Nail, cord and rod above the cloth.
    static let cord: CGFloat = 24
    /// How far the rod reaches past the cloth, both sides together.
    static let rodOverhang: CGFloat = 16
    /// The ball charm below the tip.
    static let charm: CGFloat = 32
    static let firstHeight: CGFloat = 262
    static let height: CGFloat = 224
}

/// The top three as club pennants, each on its own rod. On the screen's first
/// reveal they drop open one after another and swing, their ball charms trailing a
/// beat behind; the winner gets a floodlight and confetti. A tap swings a pennant
/// again and opens the player. Missing places hang as open outlines.
struct LeaderboardPennants: View {
    let entries: [LeaderboardEntry]
    let animateEntrance: Bool
    var onSelect: (LeaderboardEntry) -> Void = { _ in }
    @State private var lightsOnAppear: Bool
    @State private var lit = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entries: [LeaderboardEntry], animateEntrance: Bool, onSelect: @escaping (LeaderboardEntry) -> Void = { _ in }) {
        self.entries = entries
        self.animateEntrance = animateEntrance
        self.onSelect = onSelect
        _lightsOnAppear = State(initialValue: animateEntrance)
    }

    var body: some View {
        GeometryReader { geometry in
            let cloth = max(0, geometry.size.width - 2 * 6 - 3 * PennantMetrics.rodOverhang)
            HStack(alignment: .top, spacing: 6) {
                // Slots keep their identity, so tab changes update pennants in place.
                ForEach([2, 1, 3], id: \.self) { place in
                    PennantSlot(place: place, entry: entries.indices.contains(place - 1) ? entries[place - 1] : nil,
                                width: min(place == 1 ? 136 : 120, cloth * (place == 1 ? 0.36 : 0.32)),
                                animateEntrance: animateEntrance, onSelect: onSelect)
                        .zIndex(place == 1 ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: PennantMetrics.cord + PennantMetrics.firstHeight + PennantMetrics.charm)
        .background(alignment: .top) {
            if !entries.isEmpty { floodlight }
        }
        .task {
            guard lightsOnAppear else { return }
            lightsOnAppear = false
            lit += 1
        }
    }

    /// A floodlight behind the winner that stutters on like a stadium lamp as
    /// their pennant opens.
    private var floodlight: some View {
        KeyframeAnimator(initialValue: lightsOnAppear && !reduceMotion ? 0.0 : 1.0, trigger: reduceMotion ? 0 : lit) { glow in
            Circle()
                .fill(RadialGradient(colors: [LeaderboardStyle.lime.opacity(0.42), LeaderboardStyle.lime.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .offset(y: -16)
                .opacity(glow)
        } keyframes: { _ in
            // The winner's pennant opens 0.7 s into the reveal.
            LinearKeyframe(0, duration: 0.7)
            LinearKeyframe(1, duration: 0.05)
            LinearKeyframe(0.25, duration: 0.07)
            LinearKeyframe(1, duration: 0.06)
            LinearKeyframe(0.5, duration: 0.05)
            LinearKeyframe(1, duration: 0.14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PennantHang {
    /// The cloth's fold under the rod: -88 is edge-on, 0 hangs straight.
    var drop: Double = 0
    var swing: Double = 0
    var charm: Double = 0
    var shown: Double = 1
    static let folded = PennantHang(drop: -88, shown: 0)
}

private struct PennantSlot: View {
    let place: Int
    let entry: LeaderboardEntry?
    let width: CGFloat
    let onSelect: (LeaderboardEntry) -> Void
    // Capture the folded pose apart from the consumed trigger, so later tab
    // changes and refreshes mount hanging open instead of dropping again.
    @State private var startsFolded: Bool
    @State private var opensOnAppear: Bool
    @State private var reveal = 0
    @State private var pushes = 0
    @State private var counted: Bool
    @State private var celebrates = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(place: Int, entry: LeaderboardEntry?, width: CGFloat, animateEntrance: Bool,
         onSelect: @escaping (LeaderboardEntry) -> Void) {
        self.place = place
        self.entry = entry
        self.width = width
        self.onSelect = onSelect
        _startsFolded = State(initialValue: animateEntrance)
        _opensOnAppear = State(initialValue: animateEntrance)
        _counted = State(initialValue: !animateEntrance)
    }

    private var first: Bool { place == 1 }
    private var height: CGFloat { first ? PennantMetrics.firstHeight : PennantMetrics.height }
    /// Second drops first, then third, then the winner.
    private var delay: Double { first ? 0.28 : place == 2 ? 0.04 : 0.14 }
    /// When the cloth has dropped open, from the start of the reveal.
    private var opened: Double { delay + 0.42 }
    /// Which way it swings first.
    private var side: Double { place == 2 ? -1 : 1 }

    var body: some View {
        Group {
            if let entry {
                Button {
                    pushes += 1
                    onSelect(entry)
                } label: { hanging(entry) }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: pushes)
                .accessibilityLabel("Rank \(entry.rank), \(entry.isYou ? String(localized: "you") : entry.name), \(entry.touches) touches")
                .accessibilityIdentifier("leaderboard-pennant-\(entry.rank)")
            } else {
                hanging(nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(LeaderboardStyle.ordinalPlace(place)) place open")
            }
        }
        .frame(width: width + PennantMetrics.rodOverhang,
               height: PennantMetrics.cord + height + PennantMetrics.charm, alignment: .top)
        // Confetti sits outside the button, so it never widens the tap area or
        // the frame VoiceOver outlines.
        .overlay(alignment: .top) {
            if first, entry != nil {
                PennantConfetti(fire: celebrates, delay: opened)
                    .offset(y: PennantMetrics.cord + 56)
            }
        }
        .task {
            guard opensOnAppear else { return }
            opensOnAppear = false
            guard !reduceMotion else { counted = true; return }
            reveal += 1
            celebrates = first && entry != nil
            try? await Task.sleep(for: .seconds(opened))
            withAnimation(.smooth(duration: 0.9)) { counted = true }
        }
    }

    private func hanging(_ entry: LeaderboardEntry?) -> some View {
        KeyframeAnimator(initialValue: startsFolded && !reduceMotion ? PennantHang.folded : PennantHang(),
                         trigger: reduceMotion ? 0 : reveal) { hang in
            KeyframeAnimator(initialValue: PennantHang(), trigger: reduceMotion ? 0 : pushes) { push in
                ZStack(alignment: .top) {
                    fabric(entry, flap: hang.drop + push.drop, charm: hang.charm + push.charm)
                        .opacity(hang.shown)
                        .padding(.top, PennantMetrics.cord)
                    PennantRod(width: width + PennantMetrics.rodOverhang, open: entry == nil)
                }
                .contentShape(.rect)
                // The whole pennant pivots on its nail.
                .rotationEffect(.degrees(hang.swing + push.swing), anchor: .top)
            } keyframes: { _ in
                KeyframeTrack(\.swing) {
                    LinearKeyframe(side * -6, duration: 0.14, timingCurve: .easeOut)
                    SpringKeyframe(0, duration: 1.4, spring: Spring(duration: 0.7, bounce: 0.6))
                }
                KeyframeTrack(\.drop) {
                    LinearKeyframe(-10, duration: 0.1, timingCurve: .easeOut)
                    SpringKeyframe(0, duration: 0.6, spring: Spring(duration: 0.45, bounce: 0.5))
                }
                KeyframeTrack(\.charm) {
                    LinearKeyframe(0, duration: 0.08)
                    LinearKeyframe(side * 18, duration: 0.18, timingCurve: .easeOut)
                    SpringKeyframe(0, duration: 1.7, spring: Spring(duration: 0.85, bounce: 0.65))
                }
            }
        } keyframes: { _ in
            KeyframeTrack(\.shown) {
                LinearKeyframe(0, duration: delay)
                LinearKeyframe(1, duration: 0.08)
            }
            // The cloth falls open from the rod and flaps past straight before settling.
            KeyframeTrack(\.drop) {
                LinearKeyframe(PennantHang.folded.drop, duration: delay)
                SpringKeyframe(0, duration: 0.8, spring: Spring(duration: 0.55, bounce: 0.38))
            }
            KeyframeTrack(\.swing) {
                LinearKeyframe(0, duration: delay + 0.2)
                LinearKeyframe(side * 5, duration: 0.2, timingCurve: .easeOut)
                SpringKeyframe(0, duration: 1.4, spring: Spring(duration: 0.75, bounce: 0.55))
            }
            // The charm lags the cloth, then swings the other way.
            KeyframeTrack(\.charm) {
                LinearKeyframe(0, duration: delay + 0.3)
                LinearKeyframe(-side * 16, duration: 0.24, timingCurve: .easeOut)
                SpringKeyframe(0, duration: 1.8, spring: Spring(duration: 0.9, bounce: 0.6))
            }
        }
    }

    /// The cloth and its charm, which fold and flap together under the rod.
    private func fabric(_ entry: LeaderboardEntry?, flap: Double, charm: Double) -> some View {
        VStack(spacing: -2) {
            PennantCloth(entry: entry, place: place, width: width, height: height, counted: counted)
            Group {
                if entry != nil {
                    VStack(spacing: 0) {
                        Capsule().fill(Color(red: 0.3, green: 0.25, blue: 0.2)).frame(width: 1.5, height: 11)
                        LeaderboardBall(size: first ? 20 : 17)
                    }
                    .rotationEffect(.degrees(charm), anchor: .top)
                } else {
                    Color.clear
                }
            }
            .frame(height: PennantMetrics.charm, alignment: .top)
        }
        // A new player or score on this pennant flaps it.
        .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? "" : entry.map { "\($0.name)|\($0.touches)" } ?? "") { view, flutter in
            view.rotation3DEffect(.degrees(flutter), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.6)
        } keyframes: { _ in
            LinearKeyframe(-16, duration: 0.12, timingCurve: .easeOut)
            SpringKeyframe(0, duration: 0.7, spring: Spring(duration: 0.5, bounce: 0.5))
        }
        .rotation3DEffect(.degrees(flap), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.6)
    }
}

/// The rod with its cord meeting at a nail above.
private struct PennantRod: View {
    let width: CGFloat
    var open = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let cord = scheme == .dark ? Color(white: 0.7) : Color(red: 0.3, green: 0.25, blue: 0.2)
        ZStack(alignment: .top) {
            Path { path in
                path.move(to: CGPoint(x: 9, y: 25))
                path.addLine(to: CGPoint(x: width / 2, y: 3))
                path.addLine(to: CGPoint(x: width - 9, y: 25))
            }
            .stroke(cord.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.88), Color(white: 0.42)], center: UnitPoint(x: 0.35, y: 0.35),
                                     startRadius: 0, endRadius: 4))
                .frame(width: 7, height: 7)
            // A wooden dowel with brass ends.
            HStack(spacing: -2) {
                finial
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.82, green: 0.66, blue: 0.45), Color(red: 0.5, green: 0.35, blue: 0.21)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 7)
                finial
            }
            .frame(width: width)
            .offset(y: 19)
        }
        .frame(width: width, height: 30, alignment: .top)
        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
        .opacity(open ? 0.4 : 1)
        .accessibilityHidden(true)
    }

    private var finial: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.92, blue: 0.64), LeaderboardStyle.gold,
                                          Color(red: 0.48, green: 0.36, blue: 0.13)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 7))
            .frame(width: 11, height: 11)
    }
}

/// The cloth: felt in the place's colour, a woven trim and stitching, a sleeve
/// round the rod, then the player. An open place is a dashed outline.
private struct PennantCloth: View {
    let entry: LeaderboardEntry?
    let place: Int
    let width: CGFloat
    let height: CGFloat
    let counted: Bool
    @Environment(\.colorScheme) private var scheme

    private var first: Bool { place == 1 }
    private var notch: CGFloat { width * 0.34 }

    private var colors: [Color] {
        switch place {
        case 1: [LeaderboardStyle.lime, LeaderboardStyle.limeDeep]
        case 2: [LeaderboardStyle.silver, LeaderboardStyle.silverDeep]
        default: [LeaderboardStyle.bronze, LeaderboardStyle.bronzeDeep]
        }
    }
    private var trim: Color {
        switch place {
        case 1: Color(red: 0.42, green: 0.55, blue: 0.12)
        case 2: Color(red: 0.55, green: 0.57, blue: 0.55)
        default: Color(red: 0.55, green: 0.32, blue: 0.18)
        }
    }
    private var ink: Color { place == 3 ? Color(red: 0.3, green: 0.16, blue: 0.08) : LeaderboardStyle.ink }
    private var ring: Color {
        if entry?.isYou == true { return LeaderboardStyle.lime }
        switch place {
        case 1: return Color(red: 0.36, green: 0.48, blue: 0.12)
        case 2: return .white
        default: return Color(red: 0.98, green: 0.84, blue: 0.7)
        }
    }

    var body: some View {
        if let entry { woven(entry) } else { open }
    }

    private func woven(_ entry: LeaderboardEntry) -> some View {
        let shape = PennantShape(notch: notch)
        return ZStack(alignment: .top) {
            shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            PennantFelt().equatable().clipShape(shape)
            // Soft folds at the edges and a sheen down the middle.
            shape.fill(LinearGradient(stops: [
                .init(color: .black.opacity(0.14), location: 0),
                .init(color: .clear, location: 0.2),
                .init(color: .white.opacity(0.1), location: 0.46),
                .init(color: .clear, location: 0.72),
                .init(color: .black.opacity(0.14), location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            PennantShape(notch: notch, inset: 3.5).stroke(trim, lineWidth: 2.5)
            PennantShape(notch: notch, inset: 8)
                .stroke(ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // The sleeve round the rod, with its seam.
            VStack(spacing: 0) {
                Rectangle().fill(.black.opacity(0.17)).frame(height: 13)
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            }
            content(entry).padding(.top, 24)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(0.24), radius: 8, y: 6)
    }

    private func content(_ entry: LeaderboardEntry) -> some View {
        let score = counted ? entry.touches : 0
        return VStack(spacing: 0) {
            LeaderboardMedallion(entry: entry, size: first ? 64 : 54, ring: ring, ringWidth: first ? 3.5 : 3)
                .shadow(color: first ? LeaderboardStyle.lime.opacity(0.75) : .clear, radius: 8)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(entry.rank)").font(LeaderboardStyle.number(first ? 58 : 48))
                Text(LeaderboardStyle.ordinal(entry.rank)).font(LeaderboardStyle.number(first ? 18 : 15))
            }
            .padding(.top, first ? 14 : 12)
            .frame(height: first ? 58 : 50)
            // A lit lower edge, as if embroidered.
            .shadow(color: .white.opacity(0.35), radius: 0, y: 1)
            Text(entry.isYou ? String(localized: "You") : entry.name)
                .font(.system(size: first ? 15 : 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .contentTransition(.opacity)
            HStack(spacing: 2) {
                if first { Image(systemName: "laurel.leading").font(.system(size: 20, weight: .medium)).opacity(0.65) }
                Text(score.formatted())
                    .font(LeaderboardStyle.number(first ? 30 : 26))
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .contentTransition(.numericText(value: Double(score)))
                    .padding(.top, 4)
                if first { Image(systemName: "laurel.trailing").font(.system(size: 20, weight: .medium)).opacity(0.65) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .animation(SessionMotion.pop, value: entry.touches)
        }
        .foregroundStyle(ink)
        .frame(width: width)
    }

    private var open: some View {
        let muted = TrainingHomeStyle.muted(scheme)
        return ZStack(alignment: .top) {
            PennantShape(notch: notch).fill(TrainingHomeStyle.ink(scheme).opacity(0.03))
            PennantShape(notch: notch, inset: 1)
                .stroke(LeaderboardStyle.line(scheme), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(LeaderboardStyle.line(scheme), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Text("?").font(LeaderboardStyle.number(28)).foregroundStyle(muted).padding(.top, 4)
                    }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(place)").font(LeaderboardStyle.number(40))
                    Text(LeaderboardStyle.ordinal(place)).font(LeaderboardStyle.number(14))
                }
                .padding(.top, 6)
                Text("Open").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(muted)
            .padding(.top, 26)
        }
        .frame(width: width, height: height)
    }
}

/// A fine felt grain, drawn once.
private struct PennantFelt: View, Equatable {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x51F15EEDC0FFEE11
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            for index in 0..<Int(size.width * size.height / 40) {
                let point = CGPoint(x: next() * size.width, y: next() * size.height)
                let tone: Color = index % 2 == 0 ? .black : .white
                context.fill(Path(ellipseIn: CGRect(origin: point, size: CGSize(width: 1.2, height: 1.2))),
                             with: .color(tone.opacity(0.08)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Confetti

private struct ConfettiPiece: Identifiable {
    let id: Int
    let drift: CGFloat
    let apex: CGFloat
    let fall: CGFloat
    let rise: Double
    let spin: Double
    let size: CGSize
    let round: Bool
    let color: Color

    static let flight = 1.3

    /// A fixed fan of paper thrown mostly upward, the same every time.
    static let burst: [ConfettiPiece] = {
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt32.max >> 1)
        }
        let colors = [LeaderboardStyle.lime, LeaderboardStyle.gold, .white, LeaderboardStyle.bronze, LeaderboardStyle.limeDeep]
        return (0..<22).map { index in
            let angle = (next() - 0.5) * 2.4
            let apex = -(70 + next() * 100)
            return ConfettiPiece(
                id: index, drift: CGFloat(sin(angle) * (90 + next() * 90)), apex: apex,
                fall: apex + 150 + next() * 70, rise: 0.32 + next() * 0.16, spin: (next() - 0.5) * 1000,
                size: index % 3 == 0 ? CGSize(width: 7, height: 7) : CGSize(width: 5, height: 10),
                round: index % 3 == 0, color: colors[index % colors.count])
        }
    }()
}

private struct ConfettiFlight {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var spin: Double = 0
    var opacity: Double = 0
}

/// One burst over the winner, thrown once their pennant has dropped open.
private struct PennantConfetti: View {
    let fire: Bool
    let delay: Double

    var body: some View {
        ZStack {
            ForEach(ConfettiPiece.burst) { piece in
                RoundedRectangle(cornerRadius: piece.round ? piece.size.width / 2 : 1.2)
                    .fill(piece.color)
                    .frame(width: piece.size.width, height: piece.size.height)
                    .keyframeAnimator(initialValue: ConfettiFlight(), trigger: fire) { paper, flight in
                        paper
                            .rotation3DEffect(.degrees(flight.spin), axis: (x: 1, y: 0.4, z: 0.2))
                            .offset(x: flight.x, y: flight.y)
                            .opacity(flight.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.x) {
                            LinearKeyframe(0, duration: delay)
                            LinearKeyframe(piece.drift, duration: ConfettiPiece.flight, timingCurve: .easeOut)
                        }
                        KeyframeTrack(\.y) {
                            LinearKeyframe(0, duration: delay)
                            LinearKeyframe(piece.apex, duration: piece.rise, timingCurve: .easeOut)
                            LinearKeyframe(piece.fall, duration: ConfettiPiece.flight - piece.rise, timingCurve: .easeIn)
                        }
                        KeyframeTrack(\.spin) {
                            LinearKeyframe(0, duration: delay)
                            LinearKeyframe(piece.spin, duration: ConfettiPiece.flight)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: delay)
                            LinearKeyframe(1, duration: 0.02)
                            LinearKeyframe(1, duration: ConfettiPiece.flight * 0.55)
                            LinearKeyframe(0, duration: ConfettiPiece.flight * 0.45)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
