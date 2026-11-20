#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

extension WallPartyPlayer {
    var tint: Color { self == .one ? Color(red: 0.04, green: 0.83, blue: 1) : Color(red: 1, green: 0.56, blue: 0.08) }
}

extension WallCrossCircle {
    static var preview: Self {
        var state = Self()
        for (i, cell) in [5, 1, 9, 3].enumerated() {
            let r = WallTargetLayout.crossCircle.target(cell)!.frame, t = Double(i) * 4
            state.hit(point: CGPoint(x: r.midX, y: r.midY), contact: t, now: t)
        }
        return state
    }
}

struct WallCrossCircleBoard: View {
    let state: WallCrossCircle
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let board = CGRect(origin: .zero, size: geo.size), h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.01, green: 0.025, blue: 0.06), .black], startPoint: .top, endPoint: .bottom)
                ForEach(WallTargetLayout.crossCircle.targets) { target in
                    let f = target.screenFrame(in: board)
                    let owner = state.cells[target.id]
                    let won = state.winningLine.contains(target.id)
                    Group {
                        if let owner {
                            WallCrossCircleFilledTile(player: owner, won: won, boardHeight: h)
                        } else {
                            WallCrossCircleEmptyTile()
                        }
                    }
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    .accessibilityLabel(owner.map { "\($0.mark), occupied" } ?? "Empty square")
                }
                if let first = state.winningLine.first, let last = state.winningLine.last,
                   let a = WallTargetLayout.crossCircle.target(first)?.screenFrame(in: board),
                   let b = WallTargetLayout.crossCircle.target(last)?.screenFrame(in: board) {
                    Path { p in p.move(to: CGPoint(x: a.midX, y: a.midY)); p.addLine(to: CGPoint(x: b.midX, y: b.midY)) }
                        .stroke(.white, style: StrokeStyle(lineWidth: h * 0.012, lineCap: .round))
                        .shadow(color: state.winner?.tint ?? .white, radius: h * 0.025)
                }
                if let event = state.events.last, event.kind == "occupied_cell", time - event.time < 1.3 {
                    Text("TAKEN · TRY AN EMPTY SQUARE")
                        .font(.system(size: h * 0.044, weight: .black, design: .rounded))
                        .foregroundStyle(.white).padding(h * 0.025)
                        .background(.black.opacity(0.95), in: Capsule())
                }
            }.clipped()
        }
    }
}

/// Keep the original white marks and coloured glow for claimed squares. Both
/// materials use the same target frame; the bevel never shrinks the hit area.
private struct WallCrossCircleFilledTile: View {
    let player: WallPartyPlayer
    let won: Bool
    let boardHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = boardHeight
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.024)
                    .fill(LinearGradient(colors: [player.tint.opacity(0.48), .black.opacity(0.9)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: player.tint.opacity(won ? 0.8 : 0.15), radius: h * 0.016)
                RoundedRectangle(cornerRadius: h * 0.024)
                    .strokeBorder(won ? .white : player.tint, lineWidth: h * (won ? 0.014 : 0.006))
                WallPartyMark(player: player)
                    .stroke(.white, style: StrokeStyle(lineWidth: h * 0.024, lineCap: .round))
                    .frame(width: geo.size.height * 0.52, height: geo.size.height * 0.52)
                    .shadow(color: player.tint, radius: h * 0.012)
            }
        }
    }
}

/// The clearer empty state keeps its raised rim and bold centre cue.
private struct WallCrossCircleEmptyTile: View {

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let tint = Color(red: 0.48, green: 0.63, blue: 0.76)
            let shape = RoundedRectangle(cornerRadius: h * 0.085, style: .continuous)
            ZStack {
                shape.fill(Color(red: 0.015, green: 0.035, blue: 0.06))
                shape.fill(LinearGradient(
                    colors: [tint.opacity(0.24), tint.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                // Slim bevel keeps the raised edge without crowding the tile.
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.92), tint.opacity(0.5), tint.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: h * 0.028)
                shape.inset(by: h * 0.031).strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.6), .clear, .black.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom), lineWidth: h * 0.010)
                Image(systemName: "plus")
                    .font(.system(size: h * 0.20, weight: .bold))
                    .foregroundStyle(Color(red: 0.64, green: 0.74, blue: 0.82))
            }
        }
    }
}

private struct WallCrossCircleToken: View {
    let player: WallPartyPlayer

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let mark = WallPartyMark(player: player)
            let stroke = StrokeStyle(lineWidth: d * 0.20, lineCap: .round, lineJoin: .round)
            ZStack {
                mark.stroke(player.tint.opacity(0.55), style: stroke)
                    .offset(x: d * 0.025, y: d * 0.055)
                mark.stroke(LinearGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: player.tint, location: 0.38),
                    .init(color: player.tint, location: 0.78),
                    .init(color: player.tint.opacity(0.75), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), style: stroke)
                    .shadow(color: player.tint.opacity(0.32), radius: d * 0.035)
            }
        }
    }
}

private struct WallPartyMark: Shape {
    let player: WallPartyPlayer
    func path(in rect: CGRect) -> Path {
        if player == .two { return Path(ellipseIn: rect) }
        return Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
    }
}

struct WallGoalDuelBoard: View {
    let state: WallGoalDuel
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let board = CGRect(origin: .zero, size: geo.size), h = geo.size.height
            let opening = frame(WallGoalDuel.opening, in: board)
            let post = h * 0.022
            let celebrating = state.finished || time < state.readyAt
            let parts = celebrating ? state.shots.last?.keeper ?? state.keeper(at: time) : state.keeper(at: time)
            ZStack(alignment: .topLeading) {
                WallStadium()
                // Net and posts describe exactly the goal opening used by the rules.
                Rectangle().fill(Color(red: 0.01, green: 0.065, blue: 0.10).opacity(0.88))
                    .frame(width: opening.width, height: opening.height).position(x: opening.midX, y: opening.midY)
                Canvas { context, _ in
                    var net = Path()
                    for i in 0...20 {
                        let x = opening.minX + Double(i) / 20 * opening.width
                        net.move(to: CGPoint(x: x, y: opening.minY)); net.addLine(to: CGPoint(x: x, y: opening.maxY))
                    }
                    for i in 0...9 {
                        let y = opening.minY + Double(i) / 9 * opening.height
                        net.move(to: CGPoint(x: opening.minX, y: y)); net.addLine(to: CGPoint(x: opening.maxX, y: y))
                    }
                    context.stroke(net, with: .color(.cyan.opacity(0.30)), lineWidth: h * 0.002)
                }
                Path { p in
                    p.move(to: CGPoint(x: opening.minX - post / 2, y: opening.maxY))
                    p.addLine(to: CGPoint(x: opening.minX - post / 2, y: opening.minY - post / 2))
                    p.addLine(to: CGPoint(x: opening.maxX + post / 2, y: opening.minY - post / 2))
                    p.addLine(to: CGPoint(x: opening.maxX + post / 2, y: opening.maxY))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: post, lineCap: .square, lineJoin: .round))
                .shadow(color: .cyan.opacity(0.65), radius: h * 0.012)
                Path { p in
                    p.move(to: CGPoint(x: opening.minX, y: opening.maxY)); p.addLine(to: CGPoint(x: opening.maxX, y: opening.maxY))
                }.stroke(.white.opacity(0.8), lineWidth: h * 0.006)
                ForEach(parts) { part in
                    let f = frame(part.frame, in: board)
                    WallRobotPart(id: part.id)
                        .frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
                }
                if let shot = state.shots.last, let point = shot.point {
                    let age = time - shot.time
                    if age >= 0 && age < 3 {
                        let tint = shot.outcome == .goal ? Color.cyan : Color.orange
                        Circle().stroke(tint.opacity(max(0, 1 - age / 1.1)), lineWidth: h * 0.014)
                            .frame(width: h * (0.12 + min(age, 1.1) * 0.30))
                            .position(x: point.x / 3 * board.width, y: point.y / 2 * h)
                        Image(systemName: shot.outcome == .goal ? "soccerball" : "xmark.circle.fill")
                            .font(.system(size: h * 0.09, weight: .black))
                            .foregroundStyle(.white, tint)
                            .position(x: point.x / 3 * board.width, y: point.y / 2 * h)
                    }
                }
                if celebrating, let shot = state.shots.last {
                    let title = shot.outcome == .goal ? "GOAL!" : shot.outcome == .saved ? "SAVED!" : shot.outcome == .wide ? "WIDE!" : "TIME UP"
                    Text(title).font(.system(size: h * 0.10, weight: .black, design: .rounded))
                        .foregroundStyle(.white).padding(.horizontal, h * 0.06).padding(.vertical, h * 0.014)
                        .background((shot.outcome == .goal ? Color.blue : Color.orange).opacity(0.90), in: Capsule())
                        .position(x: board.midX, y: h * 0.20)
                }
            }.clipped()
        }
    }
    private func frame(_ r: CGRect, in board: CGRect) -> CGRect {
        CGRect(x: r.minX / 3 * board.width, y: r.minY / 2 * board.height,
               width: r.width / 3 * board.width, height: r.height / 2 * board.height)
    }
}

/// Static Canvas geometry is composited by the GPU; only the keeper and brief
/// impact rings animate. No particles or full-screen fire simulation.
private struct WallStadium: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.065), Color(red: 0.02, green: 0.14, blue: 0.11)],
                               startPoint: .top, endPoint: .bottom)
                Canvas { c, _ in
                    for row in 0..<4 {
                        for col in 0..<36 {
                            let r = CGRect(x: Double(col) * w / 36, y: h * (0.02 + Double(row) * 0.021),
                                           width: w * 0.014, height: h * 0.008)
                            c.fill(Path(roundedRect: r, cornerRadius: 1), with: .color((col + row) % 3 == 0 ? .cyan.opacity(0.6) : .white.opacity(0.20)))
                        }
                    }
                    for i in 0..<12 {
                        let x = Double(i) / 11 * w
                        var p = Path()
                        p.move(to: CGPoint(x: w * 0.5 + (x - w * 0.5) * 0.35, y: h * 0.85))
                        p.addLine(to: CGPoint(x: x, y: h))
                        c.stroke(p, with: .color(.green.opacity(0.18)), lineWidth: h * 0.014)
                    }
                    for x in [0.06, 0.94] {
                        let r = CGRect(x: w * x - h * 0.035, y: h * 0.06, width: h * 0.07, height: h * 0.018)
                        c.fill(Path(roundedRect: r, cornerRadius: h * 0.004), with: .color(.white))
                    }
                }
            }
        }
    }
}

private struct WallRobotPart: View {
    let id: Int
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let glove = id == 4 || id == 5
            let tint: Color = glove ? .orange : Color(red: 0.12, green: 0.65, blue: 1)
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.10)
                    .fill(LinearGradient(colors: [.white.opacity(0.95), tint, Color(red: 0.02, green: 0.12, blue: 0.28)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: h * 0.10).strokeBorder(.white.opacity(0.85), lineWidth: max(1, h * 0.035))
                if id == 0 {
                    RoundedRectangle(cornerRadius: h * 0.12).fill(.black.opacity(0.85))
                        .frame(width: geo.size.width * 0.78, height: h * 0.42)
                    HStack(spacing: geo.size.width * 0.20) {
                        Capsule().fill(.cyan).frame(width: geo.size.width * 0.15, height: h * 0.10)
                        Capsule().fill(.cyan).frame(width: geo.size.width * 0.15, height: h * 0.10)
                    }
                } else if id == 1 {
                    Image(systemName: "bolt.shield.fill").resizable().scaledToFit()
                        .foregroundStyle(.white, Color(red: 0.02, green: 0.10, blue: 0.21))
                        .padding(h * 0.22)
                } else if glove {
                    VStack(spacing: h * 0.08) {
                        ForEach(0..<3, id: \.self) { _ in Capsule().fill(.black.opacity(0.25)).frame(height: h * 0.05) }
                    }.padding(.horizontal, geo.size.width * 0.22)
                }
            }.shadow(color: .black.opacity(0.8), radius: h * 0.04, x: h * 0.04, y: h * 0.05)
        }
    }
}

struct WallPartyHUD: View {
    @ObservedObject var model: WallTargetsModel
    let height: CGFloat
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !model.isPlaying || model.alignmentStatus != .ready)) { _ in
            let time = model.arcadeTime(), switching = time < model.partyReadyAt
            if model.game == .crossCircle {
                crossCircleHeader(switching: switching)
            } else {
                HStack {
                    player(.one)
                    Spacer()
                    VStack(spacing: height * 0.004) {
                        Text(model.partyFinished ? model.partyResultTitle : model.alignmentStatus != .ready ? "HOLD ON"
                             : switching ? "WAIT · \(model.partyPlayer.name)" : turnTitle)
                            .font(.system(size: height * 0.052, weight: .black, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(detail(at: time))
                            .font(.system(size: height * 0.027, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    player(.two)
                }.foregroundStyle(.white)
            }
        }
    }

    private func crossCircleHeader(switching: Bool) -> some View {
        let paused = model.alignmentStatus != .ready
        let title = model.partyFinished ? model.partyResultTitle
            : paused ? "HOLD ON" : switching ? "GET READY" : "YOUR TURN"
        return HStack(spacing: height * 0.025) {
            crossCirclePlayer(.one)
            Spacer(minLength: 0)
            HStack(spacing: height * 0.025) {
                if !model.partyFinished && !paused {
                    WallCrossCircleToken(player: model.partyPlayer)
                        .frame(width: height * 0.048, height: height * 0.048)
                        .accessibilityLabel(model.partyPlayer.mark)
                }
                Text(title)
                    .font(.system(size: height * 0.066, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            crossCirclePlayer(.two)
        }
    }

    private func crossCirclePlayer(_ player: WallPartyPlayer) -> some View {
        let active = !model.partyFinished && model.partyPlayer == player
        return HStack(spacing: height * 0.018) {
            WallCrossCircleToken(player: player)
                .frame(width: height * 0.032, height: height * 0.032)
            Text("P\(player.rawValue)")
                .font(.system(size: height * 0.038, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: height * 0.15, height: height * 0.078)
        .background(player.tint.opacity(active ? 0.28 : 0.10), in: RoundedRectangle(cornerRadius: height * 0.015))
        .overlay {
            RoundedRectangle(cornerRadius: height * 0.015)
                .strokeBorder(player.tint.opacity(active ? 1 : 0.55), lineWidth: height * (active ? 0.005 : 0.002))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Player \(player.rawValue), \(player.mark)\(active ? ", current player" : "")")
    }
    private var turnTitle: String {
        let name = model.partyPlayer.name
        if model.game == .crossCircle { return "\(model.partyPlayer.mark) · YOUR TURN" }
        if model.game == .fourInRow { return "\(name) · CHOOSE A COLUMN" }
        if let state = model.copyMyShot { return "\(name) · " + (state.target == nil ? "SET A SPOT" : "MATCH THIS SPOT") }
        return "\(name) · SHOOT"
    }
    private func detail(at time: Double) -> String {
        if time < model.partyReadyAt { return "GET READY" }
        if model.game == .crossCircle { return "THREE IN A ROW" }
        if model.game == .fourInRow { return "CONNECT FOUR · ACROSS, UP OR DIAGONAL" }
        let deadline = model.territoryDuel?.deadline ?? model.copyMyShot?.deadline ?? model.goalDuel?.deadline ?? 20
        let seconds = max(0, Int(ceil(deadline - max(time, model.partyReadyAt))))
        if let state = model.territoryDuel { return "SHOT \(state.shotNumber) / 10 · \(seconds)s" }
        if let state = model.copyMyShot { return "CHALLENGE \(state.challengeNumber) / 6 · \(seconds)s" }
        return "SHOT \(model.goalDuel?.shotNumber ?? 1) / 5 · \(seconds)s"
    }
    private func player(_ player: WallPartyPlayer) -> some View {
        VStack(spacing: height * 0.002) {
            Text("P\(player.rawValue)").font(.system(size: height * 0.022, weight: .bold))
            Text(model.game == .crossCircle ? player.mark : model.game == .fourInRow ? "●" : "\(model.partyScore(player))")
                .font(.system(size: height * 0.060, weight: .black, design: .rounded))
        }.foregroundStyle(model.game == .crossCircle || model.game == .goalDuel ? player.tint : player.battleTint).frame(width: height * 0.12)
    }
}
#endif
