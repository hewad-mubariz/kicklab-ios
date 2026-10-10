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
    static let night = Color(red: 0.12, green: 0.16, blue: 0.135)
    static let nightDeep = Color(red: 0.06, green: 0.085, blue: 0.07)
    static let silver = Color(red: 0.93, green: 0.935, blue: 0.92)
    static let silverDeep = Color(red: 0.76, green: 0.775, blue: 0.75)
    static let gold = Color(red: 0.8, green: 0.66, blue: 0.32)
    static func number(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .title) }
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

/// The two slanted bottom edges, stroked with dashes into a short fringe.
private struct PennantFringe: Shape {
    var notch: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - notch))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - notch))
        return path
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

/// One of the top three. Unfurls on the screen's first reveal only;
/// tab changes update its contents without folding it again.
struct LeaderboardPennant: View {
    let entry: LeaderboardEntry
    let width: CGFloat
    let height: CGFloat
    /// Wait while rolled up, so the three drop one after another.
    let delay: Double
    /// Which way it swings first.
    let side: Double
    // Capture the initial pose separately from the consumed entrance trigger.
    // Otherwise starting the animation can briefly reveal the full cloth.
    @State private var startsFolded: Bool
    @State private var opensOnAppear: Bool
    @State private var pushes = 0
    @State private var reveal = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entry: LeaderboardEntry, width: CGFloat, height: CGFloat,
         animateEntrance: Bool, delay: Double, side: Double) {
        self.entry = entry; self.width = width; self.height = height
        self.delay = delay; self.side = side
        _startsFolded = State(initialValue: animateEntrance)
        _opensOnAppear = State(initialValue: animateEntrance)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The first reveal starts rolled up. Cached tabs mount fully open;
            // the child-owned task below reliably triggers delayed live results.
            KeyframeAnimator(initialValue: PennantHang(unfurl: startsFolded && !reduceMotion ? 0.03 : 1),
                             trigger: reduceMotion ? 0 : reveal) { hang in
                PennantCloth(entry: entry, width: width, height: height)
                    .scaleEffect(x: 1, y: hang.unfurl, anchor: .top)
                    .rotationEffect(.degrees(hang.swing), anchor: .top)
            } keyframes: { _ in
                KeyframeTrack(\.unfurl) {
                    LinearKeyframe(0.03, duration: delay)
                    SpringKeyframe(1, duration: 0.7, spring: Spring(duration: 0.5, bounce: 0.3))
                }
                KeyframeTrack(\.swing) {
                    LinearKeyframe(0, duration: delay + 0.1)
                    LinearKeyframe(side * 5, duration: 0.18, timingCurve: .easeOut)
                    SpringKeyframe(0, duration: 1.4, spring: Spring(duration: 0.7, bounce: 0.6))
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : pushes) { cloth, swing in
                cloth.rotationEffect(.degrees(swing), anchor: .top)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(side * -6, duration: 0.14, timingCurve: .easeOut)
                    SpringKeyframe(0, duration: 1.4, spring: Spring(duration: 0.7, bounce: 0.65))
                }
            }
            PennantRod(width: width + 14)
                .offset(y: -3)
        }
        .frame(width: width + 14, height: height, alignment: .top)
        .task {
            guard opensOnAppear else { return }
            opensOnAppear = false
            guard !reduceMotion else { return }
            reveal += 1
        }
        .contentShape(.rect)
        .onTapGesture { pushes += 1 }
        .sensoryFeedback(.impact(weight: .light), trigger: pushes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.isYou ? "you" : entry.name), \(entry.touches) touches")
        .accessibilityIdentifier("leaderboard-pennant-\(entry.rank)")
    }
}

private struct PennantHang {
    var unfurl: CGFloat
    var swing: Double = 0
}

/// The rod with its two strings meeting at a nail above.
private struct PennantRod: View {
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let wood = scheme == .dark ? Color(white: 0.62) : Color(red: 0.36, green: 0.3, blue: 0.22)
        ZStack(alignment: .top) {
            Path { path in
                path.move(to: CGPoint(x: 6, y: 26))
                path.addLine(to: CGPoint(x: width / 2, y: 2))
                path.addLine(to: CGPoint(x: width - 6, y: 26))
            }
            .stroke(wood.opacity(0.7), lineWidth: 1)
            Circle().fill(wood).frame(width: 6, height: 6)
            HStack(spacing: 0) {
                Circle().fill(wood).frame(width: 9, height: 9)
                Capsule().fill(LinearGradient(colors: [wood.opacity(0.85), wood], startPoint: .top, endPoint: .bottom))
                    .frame(height: 5)
                Circle().fill(wood).frame(width: 9, height: 9)
            }
            .offset(y: 24)
        }
        .frame(width: width, height: 34)
        .offset(y: -26)
        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }
}

/// The cloth: colour by place, a sleeve for the rod, stitching, fringe and the player.
private struct PennantCloth: View {
    let entry: LeaderboardEntry
    let width: CGFloat
    let height: CGFloat

    private var first: Bool { entry.rank == 1 }
    private var notch: CGFloat { width * 0.3 }

    private var fill: LinearGradient {
        switch entry.rank {
        case 1: LinearGradient(colors: [LeaderboardStyle.lime, LeaderboardStyle.limeDeep], startPoint: .top, endPoint: .bottom)
        case 2: LinearGradient(colors: [LeaderboardStyle.night, LeaderboardStyle.nightDeep], startPoint: .top, endPoint: .bottom)
        default: LinearGradient(colors: [LeaderboardStyle.silver, LeaderboardStyle.silverDeep], startPoint: .top, endPoint: .bottom)
        }
    }

    private var ink: Color { entry.rank == 2 ? .white : Color(red: 0.09, green: 0.12, blue: 0.06) }
    private var fringe: Color {
        switch entry.rank {
        case 1: LeaderboardStyle.limeDeep
        case 2: LeaderboardStyle.gold
        default: LeaderboardStyle.silverDeep
        }
    }
    private var ring: Color {
        if entry.isYou { return LeaderboardStyle.lime }
        switch entry.rank {
        case 1: return Color(red: 0.36, green: 0.48, blue: 0.12)
        case 2: return LeaderboardStyle.gold
        default: return .white
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            PennantFringe(notch: notch)
                .stroke(fringe, style: StrokeStyle(lineWidth: 9, dash: [1.4, 2.4]))
                .offset(y: 4)
            PennantShape(notch: notch).fill(fill)
            // Fabric: soft folds at the edges and a sleeve where the rod runs through.
            PennantShape(notch: notch)
                .fill(LinearGradient(stops: [
                    .init(color: .black.opacity(0.14), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .white.opacity(0.08), location: 0.45),
                    .init(color: .clear, location: 0.7),
                    .init(color: .black.opacity(0.14), location: 1)
                ], startPoint: .leading, endPoint: .trailing))
            Rectangle().fill(.black.opacity(0.14)).frame(height: 12)
            PennantShape(notch: notch, inset: 6)
                .stroke(ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .padding(.top, 10)
            content.padding(.top, 22)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 8, y: 6)
    }

    private var content: some View {
        VStack(spacing: 0) {
            LeaderboardMedallion(entry: entry, size: first ? 66 : 58, ring: ring, ringWidth: first ? 3.5 : 3)
                .shadow(color: first ? LeaderboardStyle.lime.opacity(0.8) : .clear, radius: 8)
            Text("\(entry.rank)")
                .font(LeaderboardStyle.number(first ? 64 : 54))
                .padding(.top, first ? 14 : 12)
                .frame(height: first ? 58 : 50)
            Text(entry.isYou ? "You" : entry.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
            HStack(spacing: 2) {
                if first { Image(systemName: "laurel.leading").font(.system(size: 22, weight: .medium)).opacity(0.65) }
                Text(entry.touches.formatted())
                    .font(LeaderboardStyle.number(first ? 32 : 28))
                    .contentTransition(.numericText(value: Double(entry.touches)))
                    .padding(.top, 4)
                if first { Image(systemName: "laurel.trailing").font(.system(size: 22, weight: .medium)).opacity(0.65) }
            }
            .padding(.top, 2)
        }
        .foregroundStyle(ink)
        .frame(width: width)
    }
}

/// A small pennant tab carrying the rank in list rows.
struct LeaderboardRankTab: View {
    let rank: Int
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            PennantShape(notch: 9)
                .fill(highlighted ? Color(red: 0.18, green: 0.25, blue: 0.07) : LeaderboardStyle.olive(scheme))
            Text("\(rank)")
                .font(LeaderboardStyle.number(rank > 99 ? 16 : 22))
                .foregroundStyle(highlighted ? LeaderboardStyle.lime : (scheme == .dark ? Color.black.opacity(0.85) : .white))
                .padding(.top, 13)
        }
        .frame(width: 38, height: 48)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}
