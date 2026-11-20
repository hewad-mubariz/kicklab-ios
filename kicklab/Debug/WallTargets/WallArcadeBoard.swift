#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

struct WallArcadeBoard: View {
    @ObservedObject var model: WallTargetsModel
    var body: some View {
        // Only the small moving scene draws at 30 fps. Rules tick once on the
        // phone, and the skyline has no time uniform or background simulation.
        TimelineView(.animation(minimumInterval: model.game == .crossCircle ? 0.1 : 1.0 / 30,
                                paused: !model.isPlaying || model.alignmentStatus != .ready)) { _ in
            let time = model.arcadeTime()
            if let memory = model.memory { WallMemoryBoard(state: memory, time: time) }
            else if let meteors = model.meteors { WallMeteorBoard(state: meteors, time: time) }
            else if let state = model.crossCircle { WallCrossCircleBoard(state: state, time: time) }
            else if let state = model.goalDuel { WallGoalDuelBoard(state: state, time: time) }
            else if let state = model.fourInRow { WallFourInRowBoard(state: state, time: time) }
            else if let state = model.territoryDuel { WallTerritoryBoard(state: state, time: time) }
            else if let state = model.copyMyShot { WallCopyShotBoard(state: state, time: time) }
        }
        .allowsHitTesting(false)
    }
}

enum WallMemorySymbol: Int, CaseIterable {
    case star = 1, moon, sun, diamond
    var name: String { switch self { case .star: "Star"; case .moon: "Moon"; case .sun: "Sun"; case .diamond: "Diamond" } }
    var image: String { switch self { case .star: "star.fill"; case .moon: "moon.fill"; case .sun: "sun.max.fill"; case .diamond: "diamond.fill" } }
    var tint: Color {
        switch self {
        case .star: Color(red: 0.05, green: 0.78, blue: 1)
        case .moon: Color(red: 1, green: 0.30, blue: 0.34)
        case .sun: Color(red: 1, green: 0.66, blue: 0.08)
        case .diamond: Color(red: 0.68, green: 0.26, blue: 1)
        }
    }
}

extension WallMemoryStrike {
    var projectorTitle: String {
        switch phase {
        case .watching: "WATCH"
        case .recalling: "YOUR TURN"
        case .interlude: retrying ? "TRY AGAIN" : "NICE!"
        case .finished: won ? "COMPLETE" : "GOOD TRY"
        }
    }
    var retrying: Bool { events.last?.kind == "retry" || events.last?.kind == "timeout" }
}

struct WallMemoryBoard: View {
    let state: WallMemoryStrike
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size), h = geo.size.height
            let latest = state.events.last(where: { $0.kind == "correct_pad" || $0.kind == "wrong_pad" })
            let recent = latest.map { time - $0.time >= 0 && time - $0.time < 0.55 } ?? false
            ZStack {
                WallArcadeBackdrop(theme: .ruins)
                ForEach(WallTargetLayout.memoryPads.targets) { pad in
                    let f = pad.screenFrame(in: rect)
                    let symbol = WallMemorySymbol(rawValue: pad.id)!
                    let lit = state.highlighted(at: time) == pad.id
                    let feedback = recent && latest?.target == pad.id
                    let flashAge = max(0, time - state.phaseStart - WallMemoryStrike.leadIn)
                        .truncatingRemainder(dividingBy: WallMemoryStrike.flash + WallMemoryStrike.gap)
                    let pulse = lit ? 0.5 + 0.5 * sin(flashAge / WallMemoryStrike.flash * .pi) : 0
                    WallMemoryTile(symbol: symbol, lit: lit, pulse: pulse, feedback: feedback ? latest?.kind : nil)
                        .frame(width: f.width, height: f.height)
                        .position(x: f.midX, y: f.midY)
                }
                Group {
                    if state.phase == .interlude {
                        Text(state.retrying ? "SAME PATTERN" : "ONE MORE SYMBOL")
                            .font(.system(size: h * 0.060, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    } else {
                        HStack(spacing: h * 0.018) {
                            ForEach(Array(state.sequence.enumerated()), id: \.offset) { index, id in
                                let symbol = WallMemorySymbol(rawValue: id)!
                                // During recall, only already-correct steps are revealed.
                                let demonstrated = state.phase == .watching && time >= state.phaseStart + WallMemoryStrike.leadIn + Double(index) * (WallMemoryStrike.flash + WallMemoryStrike.gap)
                                let confirmed = state.phase == .recalling && index < state.cursor
                                ZStack {
                                    Circle().fill(demonstrated || confirmed ? symbol.tint.opacity(0.25) : .black)
                                    Circle().stroke(demonstrated || confirmed ? .white : .white.opacity(0.65),
                                                    lineWidth: h * 0.005)
                                    if demonstrated || confirmed {
                                        Image(systemName: symbol.image).resizable().scaledToFit()
                                            .foregroundStyle(.white).padding(h * 0.020)
                                    } else {
                                        Circle().fill(.white).frame(width: h * 0.016)
                                    }
                                }.frame(width: h * 0.105, height: h * 0.105)
                                    .accessibilityLabel(demonstrated || confirmed ? symbol.name : "Unrevealed step")
                                if index < state.sequence.count - 1 {
                                    Image(systemName: "chevron.right").font(.system(size: h * 0.025, weight: .black))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }.position(x: rect.midX, y: h * 0.080)
            }.clipped()
        }
    }
}

private struct WallMemoryTile: View {
    let symbol: WallMemorySymbol
    let lit: Bool
    let pulse: Double
    let feedback: String?
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let active = lit || feedback != nil
            let tint = feedback == "wrong_pad" ? Color.red : symbol.tint
            ZStack {
                Rectangle().fill(.white).colorEffect(ShaderLibrary.wallMemoryStone(
                    .float2(geo.size), .color(tint), .float(Float(symbol.rawValue)), .float(active ? 1 : 0)))
                Image(systemName: symbol.image).resizable().scaledToFit()
                    .foregroundStyle(LinearGradient(colors: [.white, active ? .white : tint.opacity(0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: h * 0.53, height: h * 0.53)
                    .shadow(color: .black.opacity(0.85), radius: 0, x: h * 0.012, y: h * 0.025)
                    .shadow(color: tint.opacity(active ? 0.9 : 0.25), radius: h * (active ? 0.045 : 0.015))
                if active {
                    // A hard white silhouette survives ambient light better than
                    // bloom alone. The pulse uses the paused game clock.
                    WallMemoryRim()
                        .stroke(.white, lineWidth: h * (0.028 + pulse * 0.012))
                        .shadow(color: .white.opacity(0.45), radius: h * 0.018)
                }
                if feedback != nil {
                    Image(systemName: feedback == "correct_pad" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: h * 0.24, weight: .black))
                        .foregroundStyle(feedback == "correct_pad" ? Color.black : Color.red, .white)
                        .position(x: geo.size.width * 0.88, y: h * 0.21)
                }
            }
            .accessibilityLabel(symbol.name + (lit ? ", remember this symbol" : ""))
        }
    }
}

/// Matches the stone shader's cut corners without changing target geometry.
private struct WallMemoryRim: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.07)
        let cut = min(rect.height * 0.085, r.width / 4)
        return Path { p in
            p.addLines([
                CGPoint(x: r.minX + cut, y: r.minY), CGPoint(x: r.maxX - cut, y: r.minY),
                CGPoint(x: r.maxX, y: r.minY + cut), CGPoint(x: r.maxX, y: r.maxY - cut),
                CGPoint(x: r.maxX - cut, y: r.maxY), CGPoint(x: r.minX + cut, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY - cut), CGPoint(x: r.minX, y: r.minY + cut)])
            p.closeSubpath()
        }
    }
}

struct WallMeteorBoard: View {
    let state: WallMeteorDefence
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                WallArcadeBackdrop(theme: .city)
                Path { path in
                    path.move(to: CGPoint(x: w * 0.04, y: h * 0.85))
                    path.addQuadCurve(to: CGPoint(x: w * 0.96, y: h * 0.85),
                                      control: CGPoint(x: w * 0.5, y: h * 0.64))
                }.stroke(state.shields == 1 ? Color.orange.opacity(0.6) : Color.cyan.opacity(0.45),
                         style: StrokeStyle(lineWidth: h * 0.0025))
                ForEach(state.visible(at: time)) { meteor in
                    let p = meteor.position(at: time)
                    let radius = WallMeteorDefence.Meteor.radius
                    WallMeteorSprite(seed: meteor.id, time: time - meteor.spawn)
                        .frame(width: w * radius * 2 / 3, height: h * radius)
                        .position(x: p.x * w / 3, y: p.y * h / 2)
                }
                WallMeteorBursts(events: state.events, time: time)
                if state.phase == .interlude || state.phase == .finished {
                    VStack(spacing: h * 0.025) {
                        Image(systemName: state.won ? "shield.checkered" : "shield.lefthalf.filled")
                            .font(.system(size: h * 0.13, weight: .bold))
                        Text(state.phase == .interlude ? "WAVE \(state.wave) CLEAR" : state.won ? "CITY SAVED" : "CITY LOST")
                            .font(.system(size: h * 0.075, weight: .black, design: .rounded))
                        if state.phase == .interlude {
                            Text("GET READY FOR WAVE \(state.wave + 1)").font(.system(size: h * 0.031, weight: .bold))
                        }
                    }.foregroundStyle(.cyan).frame(width: w, height: h * 0.67)
                }
            }.clipped()
        }
    }
}

private struct WallMeteorSprite: View {
    let seed: Int
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // The small GPU surface includes both the bright rock and its fire.
            // The shared circular rock boundary still owns the hit test.
            WallMeteorSurface(seed: seed, time: time)
                .frame(width: w * 2.4, height: h * 3.6)
                .position(x: w * 0.5, y: -h * 0.508)
        }
    }
}

struct WallArcadeHUD: View {
    @ObservedObject var model: WallTargetsModel
    let height: CGFloat
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SCORE").font(.system(size: height * 0.023, weight: .bold))
                Text("\(model.arcadeScore)").font(.system(size: height * 0.065, weight: .black).monospacedDigit()).foregroundStyle(.cyan)
            }
            Spacer()
            VStack(spacing: height * 0.006) {
                if let memory = model.memory {
                    Text(model.isPlaying && model.alignmentStatus != .ready ? "HOLD ON" : memory.projectorTitle)
                        .font(.system(size: height * 0.068, weight: .black, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(model.game.title.uppercased()).font(.system(size: height * 0.029, weight: .heavy).width(.condensed))
                }
                Text(model.memory.map { "ROUND \($0.round) / 5" } ?? "WAVE \(model.meteors?.wave ?? 1) / 3")
                    .font(.system(size: height * (model.memory != nil ? 0.028 : 0.024), weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer()
            HStack(spacing: height * 0.015) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: model.game == .memoryStrike ? "heart.fill" : "shield.fill")
                        .font(.system(size: height * 0.035, weight: .bold))
                        .foregroundStyle(i < (model.memory?.lives ?? model.meteors?.shields ?? 3)
                            ? WallTargetsBoard.metalGold : .white.opacity(0.18))
                }
            }
        }.foregroundStyle(.white)
    }
}
#endif
