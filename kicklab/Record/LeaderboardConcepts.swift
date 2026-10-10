#if DEBUG
import SwiftUI

/// Leaderboard directions, for review only. Launch with
/// --session-design leaderboard-concept --concept A|B|C|H --lb-state <state>.
struct LeaderboardConceptView: View {
    let concept: String
    let state: String

    var body: some View {
        ZStack {
            Board.bg.ignoresSafeArea()
            switch concept {
            case "B": SkyConcept(state: state)
            case "C": StadiumBoardConcept(state: state)
            case "H": HomeEntryConcept(state: state)
            default: PodiumConcept(state: state)
            }
        }
        .foregroundStyle(Board.ink)
        .preferredColorScheme(.dark)
    }
}

private enum Board {
    static let bg = TrainingHomeStyle.background(.dark)
    static let panel = TrainingHomeStyle.panel(.dark)
    static let ink = TrainingHomeStyle.ink(.dark)
    static let muted = TrainingHomeStyle.muted(.dark)
    static let line = TrainingHomeStyle.line(.dark)
    static let lime = TrainingHomeStyle.lime
    static let buttonInk = TrainingHomeStyle.buttonInk
    static let gold = Color(red: 1, green: 0.8, blue: 0.32)
    static let down = Color(red: 1, green: 0.45, blue: 0.42)
    static func display(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .title) }
}

private struct Racer: Identifiable {
    let rank: Int
    let name: String
    let flag: String
    let touches: Int
    let skin: BallSkin
    let move: Int
    var me = false
    var id: Int { rank }
}

private let racers: [Racer] = [
    Racer(rank: 1, name: "Maya", flag: "🇧🇷", touches: 1284, skin: .gold, move: 0),
    Racer(rank: 2, name: "Kenji", flag: "🇯🇵", touches: 962, skin: .arctic, move: 1),
    Racer(rank: 3, name: "Amara", flag: "🇳🇬", touches: 811, skin: .crimson, move: -1),
    Racer(rank: 4, name: "Leo", flag: "🇪🇸", touches: 540, skin: .galaxy, move: 2),
    Racer(rank: 5, name: "Sofia", flag: "🇮🇹", touches: 433, skin: .aurora, move: 0),
    Racer(rank: 6, name: "Theo", flag: "🇫🇷", touches: 412, skin: .chrome, move: -2),
    Racer(rank: 7, name: "Ravi", flag: "🇮🇳", touches: 391, skin: .matrix, move: 1),
    Racer(rank: 8, name: "You", flag: "🇩🇪", touches: 377, skin: .graffiti, move: 3, me: true),
    Racer(rank: 9, name: "Noah", flag: "🇺🇸", touches: 350, skin: .stealth, move: -1),
    Racer(rank: 10, name: "Zoe", flag: "🇬🇧", touches: 322, skin: .classic, move: 0),
]

// MARK: - Shared pieces

private struct Avatar: View {
    let skin: BallSkin
    let size: CGFloat
    var ring = false

    var body: some View {
        BallSkinPreview(skin: skin)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.45), radius: size * 0.08, y: size * 0.06)
            .background {
                if ring {
                    Circle().fill(Board.lime.opacity(0.22)).blur(radius: size * 0.25).scaleEffect(1.3)
                    Circle().strokeBorder(Board.lime, lineWidth: 2).padding(-size * 0.12)
                }
            }
    }
}

private struct Move: View {
    let value: Int
    var body: some View {
        if value == 0 {
            Text("–").font(.caption.weight(.bold)).foregroundStyle(Board.muted)
        } else {
            HStack(spacing: 2) {
                Image(systemName: value > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                Text("\(abs(value))")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(value > 0 ? Board.lime : Board.down)
        }
    }
}

private struct BoardHeader: View {
    var title = "LEADERBOARD"
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
            Text(title).font(Board.display(32)).tracking(0.6)
            Spacer()
            HStack(spacing: 6) {
                Text("This week")
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).frame(height: 40)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

private struct ScopeSwitch: View {
    var selected = "World"
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["Friends", "Country", "World"], id: \.self) { scope in
                Text(scope)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(scope == selected ? Board.buttonInk : Board.ink.opacity(0.8))
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background { if scope == selected { Capsule().fill(Board.lime) } }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Pinned at the bottom: the one person to beat next, and how close you are.
private struct ChaseCard: View {
    var rank = 8
    var touches = 377
    var target = racers[6]
    var progress: CGFloat = 0.78

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(skin: .graffiti, size: 36, ring: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You · #\(rank)").font(.subheadline.weight(.semibold))
                    Text("\(touches) touches this week").font(.caption).foregroundStyle(Board.muted)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(target.touches - touches + 1) to pass").font(.caption).foregroundStyle(Board.muted)
                    Text(target.name).font(.subheadline.weight(.bold)).foregroundStyle(Board.lime)
                }
            }
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Board.line)
                    Capsule().fill(LinearGradient(colors: [Board.lime.opacity(0.5), Board.lime], startPoint: .leading, endPoint: .trailing))
                        .scaleEffect(x: progress, anchor: .leading)
                }
                .frame(height: 8)
                Avatar(skin: target.skin, size: 26)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

// MARK: - A · Podium

private struct PodiumConcept: View {
    let state: String
    private var climbing: Bool { state == "climb" }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                BoardHeader().padding(.top, 4)
                ScopeSwitch().padding(.top, 14)
                Podium().padding(.top, 20)
                if climbing { climbRows.padding(.top, 14) } else { rows.padding(.top, 14) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            LinearGradient(colors: [Board.bg.opacity(0), Board.bg], startPoint: .top, endPoint: .bottom)
                .frame(height: 150).allowsHitTesting(false).ignoresSafeArea()
            Group {
                if climbing { ChaseCard(rank: 6, touches: 413, target: racers[4], progress: 0.22) } else { ChaseCard() }
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(racers[3...7]) { RankRow(racer: $0) }
        }
    }

    /// You were kicked from #8 to #6: your row flies up over Theo and Ravi, who slide down.
    private var climbRows: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                RankRow(racer: racers[3])
                RankRow(racer: racers[4])
                Color.clear.frame(height: 58)
                RankRow(racer: Racer(rank: 7, name: "Theo", flag: "🇫🇷", touches: 412, skin: .chrome, move: -1))
                    .offset(y: -10).opacity(0.85)
                RankRow(racer: Racer(rank: 8, name: "Ravi", flag: "🇮🇳", touches: 391, skin: .matrix, move: -1))
                    .offset(y: -10).opacity(0.85)
            }
            // A lime streak trails the row from #8 up to #6.
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Board.lime.opacity(0.28), Board.lime.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(height: 58 + 132)
                .padding(.horizontal, 10)
                .offset(y: 66 * 2)
            RankRow(racer: Racer(rank: 6, name: "You", flag: "🇩🇪", touches: 413, skin: .graffiti, move: 2, me: true))
                .scaleEffect(1.05)
                .shadow(color: Board.lime.opacity(0.45), radius: 18, y: 6)
                .offset(y: 66 * 2 - 6)
                .overlay(alignment: .topTrailing) {
                    Text("+2")
                        .font(Board.display(24)).foregroundStyle(Board.buttonInk)
                        .padding(.horizontal, 10).padding(.top, 3).frame(height: 30)
                        .background(Board.lime, in: .capsule)
                        .rotationEffect(.degrees(8))
                        .offset(x: 6, y: 66 * 2 - 22)
                }
            Sparks().offset(y: 66 * 2 - 30)
        }
    }
}

private struct Sparks: View {
    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { index in
                let angle = Double(index) / 14 * 2 * .pi
                let distance = 46 + Double(index % 3) * 18
                Circle()
                    .fill(index % 2 == 0 ? Board.lime : Board.gold)
                    .frame(width: index % 3 == 0 ? 6 : 4, height: index % 3 == 0 ? 6 : 4)
                    .offset(x: cos(angle) * distance * 1.9, y: sin(angle) * distance * 0.6)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Podium: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            column(racers[1], block: 92, ball: 62)
            column(racers[0], block: 124, ball: 84)
            column(racers[2], block: 72, ball: 58)
        }
    }

    private func column(_ racer: Racer, block: CGFloat, ball: CGFloat) -> some View {
        let first = racer.rank == 1
        return VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Avatar(skin: racer.skin, size: ball)
                if first {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(LinearGradient(colors: [Board.gold, Color(red: 1, green: 0.62, blue: 0.2)],
                                                        startPoint: .top, endPoint: .bottom))
                        .shadow(color: Board.gold.opacity(0.6), radius: 8)
                        .rotationEffect(.degrees(-18))
                        .offset(x: -4, y: -16)
                }
            }
            Text("\(racer.flag) \(racer.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(racer.touches.formatted()).font(Board.display(first ? 30 : 24))
                .foregroundStyle(first ? Board.lime : Board.ink)
            ZStack {
                UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18)
                    .fill(first
                          ? AnyShapeStyle(LinearGradient(colors: [Board.lime, Board.lime.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [Board.panel, Board.panel.opacity(0.4)], startPoint: .top, endPoint: .bottom)))
                UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18)
                    .strokeBorder(first ? Color.white.opacity(0.35) : Board.line)
                Text("\(racer.rank)")
                    .font(Board.display(first ? 64 : 48))
                    .foregroundStyle(first ? Board.buttonInk : Board.muted)
                    .padding(.top, 8)
            }
            .frame(height: block)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RankRow: View {
    let racer: Racer

    var body: some View {
        HStack(spacing: 12) {
            Text("\(racer.rank)").font(Board.display(24))
                .foregroundStyle(racer.me ? Board.lime : Board.muted)
                .frame(width: 26)
            Avatar(skin: racer.skin, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(racer.flag) \(racer.name)").font(.body.weight(.semibold))
                Move(value: racer.move)
            }
            Spacer(minLength: 8)
            Text(racer.touches.formatted()).font(Board.display(28))
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(racer.me ? Board.lime.opacity(0.13) : Board.panel, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(racer.me ? Board.lime.opacity(0.8) : Board.line, lineWidth: racer.me ? 1.5 : 1)
        }
    }
}

// MARK: - B · Juggle Sky

private struct SkyConcept: View {
    let state: String
    private var focused: Bool { state == "tap" }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [Board.lime.opacity(0.2), Board.lime.opacity(0.04), .clear],
                               center: UnitPoint(x: 0.6, y: 0.05), startRadius: 0, endRadius: 420)
                    .ignoresSafeArea()
                ruler(width: w)
                ForEach(racers) { racer in
                    skyBall(racer, x: x(for: racer) * w, y: y(for: racer.touches))
                }
                chaseLine(width: w)
                VStack(alignment: .leading, spacing: 4) {
                    Text("JUGGLE SKY").font(Board.display(34))
                    Text("How high did you get this week?").font(.subheadline).foregroundStyle(Board.muted)
                }
                .padding(.leading, 20).padding(.top, 4)
                if focused { card(width: w) }
            }
            .overlay(alignment: .bottom) { tray.padding(.horizontal, 12).padding(.bottom, 4) }
        }
    }

    private func y(for touches: Int) -> CGFloat {
        let top = log(1300.0), bottom = log(300.0)
        return 120 + CGFloat((top - log(Double(touches))) / (top - bottom)) * 520
    }

    private func x(for racer: Racer) -> CGFloat {
        [0.56, 0.32, 0.72, 0.4, 0.74, 0.24, 0.6, 0.38, 0.8, 0.2][racer.rank - 1]
    }

    private func ruler(width: CGFloat) -> some View {
        ForEach([1200, 800, 500, 300], id: \.self) { mark in
            HStack(spacing: 8) {
                Text(mark.formatted()).font(Board.display(15)).foregroundStyle(Board.muted)
                    .frame(width: 38, alignment: .leading)
                DashLine().stroke(Board.line, style: StrokeStyle(lineWidth: 1, dash: [2, 6])).frame(height: 1)
            }
            .frame(width: width - 28, height: 16)
            .position(x: width / 2 + 2, y: y(for: mark))
        }
    }

    private func skyBall(_ racer: Racer, x: CGFloat, y: CGFloat) -> some View {
        let size: CGFloat = racer.rank == 1 ? 64 : (racer.me ? 50 : 42)
        let dim = focused && racer.rank != 2
        return VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                Avatar(skin: racer.skin, size: size, ring: racer.me || (focused && racer.rank == 2))
                if racer.rank == 1 {
                    Image(systemName: "crown.fill").font(.system(size: 20)).foregroundStyle(Board.gold)
                        .shadow(color: Board.gold.opacity(0.7), radius: 8)
                        .rotationEffect(.degrees(-18)).offset(x: -6, y: -14)
                }
            }
            HStack(spacing: 4) {
                Text(racer.me ? "YOU" : racer.name).font(.caption.weight(.bold))
                Text(racer.touches.formatted()).font(.caption).monospacedDigit()
                    .foregroundStyle(racer.me ? Board.buttonInk.opacity(0.7) : Board.muted)
            }
            .foregroundStyle(racer.me ? Board.buttonInk : Board.ink)
            .padding(.horizontal, 8).frame(height: 22)
            .background(racer.me ? AnyShapeStyle(Board.lime) : AnyShapeStyle(Board.panel.opacity(0.85)), in: .capsule)
        }
        .scaleEffect(focused && racer.rank == 2 ? 1.15 : 1)
        .opacity(dim ? 0.35 : 1)
        .position(x: x, y: y)
    }

    private func chaseLine(width: CGFloat) -> some View {
        let me = racers[7], ravi = racers[6]
        let from = CGPoint(x: x(for: me) * width, y: y(for: me.touches) - 26)
        let to = CGPoint(x: x(for: ravi) * width, y: y(for: ravi.touches) + 30)
        return ZStack {
            Path { path in
                path.move(to: from)
                path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2 + 30, y: (from.y + to.y) / 2))
            }
            .stroke(Board.lime, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6]))
            Text("+15").font(.caption.weight(.heavy)).foregroundStyle(Board.buttonInk)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Board.lime, in: .capsule)
                .position(x: (from.x + to.x) / 2 + 26, y: (from.y + to.y) / 2)
        }
        .opacity(focused ? 0.3 : 1)
    }

    private func card(width: CGFloat) -> some View {
        let kenji = racers[1]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(skin: kenji.skin, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kenji.flag) Kenji").font(.title3.weight(.bold))
                    Text("#2 this week · Arctic Ice ball").font(.caption).foregroundStyle(Board.muted)
                }
            }
            HStack(spacing: 10) {
                stat("962", "touches")
                stat("88", "best combo")
                stat("7 🔥", "day streak")
            }
            HStack(spacing: 8) {
                Text("👋")
                Text("High five")
            }
            .font(.body.weight(.semibold)).foregroundStyle(Board.buttonInk)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(Board.lime, in: .capsule)
        }
        .padding(16)
        .frame(width: width - 60)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .position(x: width / 2, y: y(for: kenji.touches) + 150)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(Board.display(24))
            Text(label).font(.caption2).foregroundStyle(Board.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Board.ink.opacity(0.06), in: .rect(cornerRadius: 14))
    }

    private var tray: some View {
        VStack(spacing: 12) {
            ScopeSwitch()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You’re #8 of 2,418").font(.subheadline.weight(.semibold))
                    Text("15 touches to pass Ravi").font(.caption).foregroundStyle(Board.lime)
                }
                Spacer()
                Text("Climb").font(.subheadline.weight(.bold)).foregroundStyle(Board.buttonInk)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(Board.lime, in: .capsule)
            }
            .padding(.horizontal, 6)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}

private struct DashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - C · Stadium board

private struct StadiumBoardConcept: View {
    let state: String
    private var flipping: Bool { state == "flip" }

    var body: some View {
        ZStack(alignment: .bottom) {
            floodlights
            VStack(alignment: .leading, spacing: 0) {
                BoardHeader(title: "TOP JUGGLERS").padding(.top, 4)
                Text("WEEK 41 · WORLD").font(.caption.weight(.bold)).tracking(2.4)
                    .foregroundStyle(Board.lime).padding(.top, 14).padding(.leading, 4)
                board.padding(.top, 10)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            ChaseCard(rank: flipping ? 6 : 8, touches: flipping ? 413 : 377,
                      target: flipping ? racers[4] : racers[6], progress: flipping ? 0.22 : 0.78)
                .padding(.horizontal, 12).padding(.bottom, 4)
        }
    }

    private var floodlights: some View {
        ZStack {
            RadialGradient(colors: [Color.white.opacity(0.14), .clear], center: UnitPoint(x: 0, y: 0), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Color.white.opacity(0.14), .clear], center: UnitPoint(x: 1, y: 0), startRadius: 0, endRadius: 300)
        }
        .ignoresSafeArea()
    }

    private var board: some View {
        VStack(spacing: 6) {
            HStack {
                Text("POS").frame(width: 46, alignment: .leading)
                Text("PLAYER")
                Spacer()
                Text("TOUCHES")
            }
            .font(.caption2.weight(.bold)).tracking(1.6).foregroundStyle(Board.muted)
            .padding(.horizontal, 6).padding(.bottom, 2)
            ForEach(racers) { racer in
                boardRow(racer)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.02, green: 0.03, blue: 0.03))
            DotMatrix().clipShape(.rect(cornerRadius: 22))
        }
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.08), lineWidth: 1.5) }
        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
    }

    private func boardRow(_ racer: Racer) -> some View {
        let isMe = racer.me
        let podium = racer.rank <= 3
        let shownRank = flipping && isMe ? 6 : racer.rank
        let shownTouches = flipping && isMe ? 413 : racer.touches
        return HStack(spacing: 8) {
            FlapNumber(value: shownRank, digits: 2, flip: flipping && isMe ? 0.55 : 0, previous: 8)
                .frame(width: 46, alignment: .leading)
            Text(isMe ? "YOU" : racer.name.uppercased())
                .font(.system(size: 17, weight: .heavy, design: .monospaced))
                .foregroundStyle(podium ? Board.gold : (isMe ? Board.lime : Board.ink.opacity(0.9)))
                .shadow(color: (podium ? Board.gold : Board.lime).opacity(isMe || podium ? 0.8 : 0.25), radius: 5)
            Text(racer.flag).font(.footnote)
            Spacer(minLength: 4)
            FlapNumber(value: shownTouches, digits: 4, flip: flipping && isMe ? 0.4 : 0, previous: 377)
        }
        .padding(.horizontal, 6).frame(height: 40)
        .background {
            if isMe {
                RoundedRectangle(cornerRadius: 10).fill(Board.lime.opacity(0.14))
                RoundedRectangle(cornerRadius: 10).strokeBorder(Board.lime.opacity(0.7))
            }
        }
        .offset(y: flipping && isMe ? -8 : 0)
    }
}

private struct DotMatrix: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 3
            while y < size.height {
                var x: CGFloat = 3
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.05)))
                    x += 5
                }
                y += 5
            }
        }
    }
}

/// Split-flap digits; `flip` tilts the top half of each tile mid-turn from `previous`.
private struct FlapNumber: View {
    let value: Int
    let digits: Int
    var flip: Double = 0
    var previous = 0

    var body: some View {
        let text = String(format: "%0\(digits)d", value).map(String.init)
        let old = String(format: "%0\(digits)d", previous).map(String.init)
        HStack(spacing: 2) {
            ForEach(text.indices, id: \.self) { index in
                let leading = index < text.count - String(value).count
                FlapTile(digit: leading ? " " : text[index],
                         previous: old[index], flip: old[index] == text[index] ? 0 : flip)
            }
        }
    }
}

private struct FlapTile: View {
    let digit: String
    let previous: String
    let flip: Double

    var body: some View {
        ZStack {
            if flip > 0 {
                // The new top is revealed behind the falling flap; the old bottom waits for it.
                tile(digit).mask(alignment: .top) { Rectangle().frame(height: 15) }
                tile(previous).mask(alignment: .bottom) { Rectangle().frame(height: 15) }
                tile(previous)
                    .mask(alignment: .top) { Rectangle().frame(height: 15) }
                    .rotation3DEffect(.degrees(flip * 160), axis: (x: -1, y: 0, z: 0), anchor: .center, perspective: 0.5)
                    .brightness(-flip * 0.5)
            } else {
                tile(digit)
            }
            Rectangle().fill(.black).frame(height: 1.2)
        }
        .frame(width: 20, height: 30)
    }

    private func tile(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 20, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 20, height: 30)
            .background(
                LinearGradient(colors: [Color(white: 0.17), Color(white: 0.1)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 4)
            )
    }
}

// MARK: - Home entry

private struct HomeEntryConcept: View {
    let state: String

    var body: some View {
        HomeView(personalBest: 377, onJuggling: {}, onPowerShot: {}, onImport: {}, onProfile: {}, onSetupGuide: {})
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if state == "guest" { GuestTeaser() } else { HomeLeaderboardCard() }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Board.bg)
                .padding(.top, 506)
            }
    }
}

private struct HomeLeaderboardCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("LEADERBOARD", systemImage: "trophy")
                    .font(.caption.weight(.semibold)).tracking(1)
                    .foregroundStyle(Board.lime)
                Spacer()
                Text("This week · World").font(.caption).foregroundStyle(Board.muted)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Board.muted)
            }
            HStack(alignment: .bottom, spacing: 16) {
                MiniPodium()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#8").font(Board.display(52))
                        Move(value: 3)
                    }
                    Text("of 2,418 jugglers").font(.caption).foregroundStyle(Board.muted)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Avatar(skin: .graffiti, size: 22)
                ZStack(alignment: .leading) {
                    Capsule().fill(Board.line)
                    Capsule().fill(Board.lime).scaleEffect(x: 0.78, anchor: .leading)
                }
                .frame(height: 6)
                Avatar(skin: .matrix, size: 22)
                Text("15 to pass Ravi").font(.caption.weight(.semibold)).foregroundStyle(Board.lime)
            }
        }
        .padding(18)
        .background(Board.panel, in: .rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Board.line) }
    }
}

private struct MiniPodium: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            step(racers[1], height: 30)
            step(racers[0], height: 44, first: true)
            step(racers[2], height: 22)
        }
    }

    private func step(_ racer: Racer, height: CGFloat, first: Bool = false) -> some View {
        VStack(spacing: 4) {
            Avatar(skin: racer.skin, size: first ? 34 : 28)
            UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
                .fill(first ? Board.lime : Board.line)
                .frame(width: 34, height: height)
                .overlay {
                    Text("\(racer.rank)").font(Board.display(18))
                        .foregroundStyle(first ? Board.buttonInk : Board.muted).padding(.top, 4)
                }
        }
    }
}

/// Signed out: the local record shows where it would land, and claiming it opens sign-in.
private struct GuestTeaser: View {
    var body: some View {
        ZStack {
            HomeLeaderboardCard().blur(radius: 7).opacity(0.55)
            VStack(spacing: 12) {
                Text("Your 377 touches would be")
                    .font(.subheadline).foregroundStyle(Board.ink.opacity(0.85))
                Text("#8 THIS WEEK").font(Board.display(40)).foregroundStyle(Board.lime)
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                    Text("Claim my spot")
                }
                .font(.body.weight(.bold)).foregroundStyle(Board.buttonInk)
                .padding(.horizontal, 22).frame(height: 48)
                .background(Board.lime, in: .capsule)
                Text("Sign in with Apple, Google or email").font(.caption).foregroundStyle(Board.muted)
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .padding(.horizontal, 18)
        }
    }
}
#endif
