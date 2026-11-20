#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

extension WallPartyPlayer {
    var battleTint: Color { self == .one ? Color(red: 0.02, green: 0.86, blue: 1) : Color(red: 1, green: 0.29, blue: 0.22) }
}

private struct BattleSpace {
    let size: CGSize
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / 3 * size.width, y: p.y / 2 * size.height) }
    func rect(_ r: CGRect) -> CGRect {
        CGRect(origin: point(r.origin), size: CGSize(width: r.width / 3 * size.width, height: r.height / 2 * size.height))
    }
    func polygon(_ vertices: [CGPoint]) -> Path {
        Path { p in p.addLines(vertices.map(point)); p.closeSubpath() }
    }
}

private let battleBackground = Color(red: 0.006, green: 0.018, blue: 0.045)

struct WallFourInRowBoard: View {
    let state: WallFourInRow
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                battleBackground
                Canvas { c, size in
                    let s = BattleSpace(size: size), frame = s.rect(WallFourInRow.board).insetBy(dx: -h * 0.014, dy: -h * 0.015)
                    c.addFilter(.shadow(color: .blue.opacity(0.65), radius: h * 0.016, y: h * 0.008))
                    let panel = Path(roundedRect: frame, cornerRadius: h * 0.025)
                    c.fill(panel, with: .linearGradient(Gradient(colors: [Color(red: 0.03, green: 0.42, blue: 0.9), Color(red: 0.01, green: 0.10, blue: 0.32)]),
                        startPoint: frame.origin, endPoint: CGPoint(x: frame.maxX, y: frame.maxY)))
                    c.stroke(panel, with: .color(.cyan), lineWidth: h * 0.005)
                    c.addFilter(.shadow(color: .clear, radius: 0))
                    for col in 0..<7 {
                        let x = s.point(WallFourInRow.centre(col + 1)).x
                        let full = state.cells[col + 1] != nil
                        let tint = full ? Color.white.opacity(0.22) : state.player.battleTint
                        var arrow = Path()
                        arrow.move(to: CGPoint(x: x, y: h * 0.038)); arrow.addLine(to: CGPoint(x: x, y: h * 0.101))
                        arrow.move(to: CGPoint(x: x - h * 0.021, y: h * 0.080))
                        arrow.addLine(to: CGPoint(x: x, y: h * 0.105)); arrow.addLine(to: CGPoint(x: x + h * 0.021, y: h * 0.080))
                        c.stroke(arrow, with: .color(tint), style: StrokeStyle(lineWidth: h * 0.009, lineCap: .round, lineJoin: .round))
                    }
                    let diameter = min(h * 0.105, size.width * 0.10)
                    for cell in 1...42 {
                        let p = s.point(WallFourInRow.centre(cell))
                        let hole = CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2, width: diameter, height: diameter)
                        c.fill(Path(ellipseIn: hole), with: .color(battleBackground))
                        c.stroke(Path(ellipseIn: hole), with: .color(.cyan.opacity(0.65)), lineWidth: h * 0.003)
                        if let owner = state.cells[cell] {
                            let drop = state.drops.last
                            let age = state.finished ? 1 : max(0, time - (drop?.time ?? 0))
                            let progress = min(1, age / 0.48)
                            let y = drop?.cell == cell ? h * 0.13 + (p.y - h * 0.13) * progress * progress : p.y
                            let chip = CGRect(x: hole.minX + h * 0.004, y: y - diameter / 2 + h * 0.004,
                                              width: diameter - h * 0.008, height: diameter - h * 0.008)
                            c.fill(Path(ellipseIn: chip), with: .linearGradient(Gradient(colors: [.white, owner.battleTint, owner.battleTint.opacity(0.65)]),
                                startPoint: chip.origin, endPoint: CGPoint(x: chip.maxX, y: chip.maxY)))
                            c.stroke(Path(ellipseIn: chip), with: .color(.white.opacity(0.9)), lineWidth: h * 0.003)
                            c.stroke(Path(ellipseIn: chip.insetBy(dx: h * 0.008, dy: h * 0.008)),
                                     with: .color(owner.battleTint.opacity(0.9)), lineWidth: h * 0.003)
                            if state.winningLine.contains(cell) {
                                c.stroke(Path(ellipseIn: hole.insetBy(dx: -h * 0.006, dy: -h * 0.006)),
                                         with: .color(.yellow), lineWidth: h * 0.009)
                            }
                        }
                    }
                    if let a = state.winningLine.first, let b = state.winningLine.last {
                        var line = Path(); line.move(to: s.point(WallFourInRow.centre(a))); line.addLine(to: s.point(WallFourInRow.centre(b)))
                        c.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: h * 0.008, lineCap: .round))
                    }
                }
                if let e = state.events.last, e.kind == "column_full", time - e.time < 1.5 {
                    battleToast("COLUMN FULL · TRY ANOTHER", tint: .orange, height: h)
                }
            }.clipped()
        }
    }
}

struct WallTerritoryBoard: View {
    let state: WallTerritoryDuel
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let event = state.events.last { $0.kind != "match_won" && $0.kind != "match_draw" }
            ZStack {
                battleBackground
                Canvas { c, size in
                    let s = BattleSpace(size: size)
                    for zone in WallTerritoryDuel.zones {
                        let owner = state.owners[zone.id], tint = owner?.battleTint ?? Color(red: 0.28, green: 0.40, blue: 0.56)
                        let p = s.polygon(zone.vertices), centre = s.point(zone.centre)
                        var depth = c
                        depth.translateBy(x: h * 0.009, y: h * 0.022)
                        depth.fill(p, with: .color(tint.opacity(0.45)))
                        depth.stroke(p, with: .color(tint.opacity(0.85)), lineWidth: h * 0.005)
                        c.fill(p, with: .linearGradient(Gradient(colors: [tint.opacity(owner == nil ? 0.3 : 0.95), tint.opacity(0.28), .black.opacity(0.8)]),
                            startPoint: CGPoint(x: centre.x - h * 0.1, y: centre.y - h * 0.15),
                            endPoint: CGPoint(x: centre.x + h * 0.1, y: centre.y + h * 0.16)))
                        c.stroke(p, with: .color(owner == nil ? .white.opacity(0.85) : tint), lineWidth: h * 0.009)
                        let inset = zone.vertices.map { CGPoint(x: zone.centre.x + ($0.x - zone.centre.x) * 0.87,
                                                               y: zone.centre.y + ($0.y - zone.centre.y) * 0.87) }
                        c.stroke(s.polygon(inset), with: .color(.white.opacity(owner == nil ? 0.12 : 0.5)), lineWidth: h * 0.002)
                        // A faceted centre and solid edge remain legible with room lights on.
                        if owner != nil {
                            let mark = CGRect(x: centre.x - h * 0.018, y: centre.y - h * 0.018, width: h * 0.036, height: h * 0.036)
                            c.fill(Path(roundedRect: mark, cornerRadius: h * 0.006), with: .color(.white.opacity(0.85)))
                        }
                        if event?.target == zone.id, time - (event?.time ?? 0) < 1.2 {
                            let age = max(0, time - (event?.time ?? 0))
                            c.stroke(p, with: .color(.white.opacity(max(0, 1 - age / 1.2))), lineWidth: h * 0.018)
                        }
                    }
                }
                if let event, time - event.time < 1.5 {
                    let label = event.kind == "zone_stolen" ? "STOLEN!" : event.kind == "zone_claimed" ? "CLAIMED!"
                        : event.kind == "zone_already_owned" ? "ALREADY YOURS" : event.kind == "turn_timeout" ? "TIME UP" : "MISSED"
                    VStack { Spacer(); battleToast(label, tint: WallPartyPlayer(rawValue: event.player ?? 1)!.battleTint, height: h) }
                }
            }.clipped()
        }
    }
}

struct WallCopyShotBoard: View {
    let state: WallCopyMyShot
    let time: Double
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let recent = state.target == nil && (state.finished || time < state.readyAt) ? state.challenges.last : nil
            let target = state.target ?? recent?.target
            ZStack {
                battleBackground
                Canvas { c, size in
                    let s = BattleSpace(size: size)
                    if let target {
                        let centre = s.point(target)
                        let ring = s.rect(CGRect(x: target.x - WallCopyMyShot.radius, y: target.y - WallCopyMyShot.radius,
                                                width: WallCopyMyShot.radius * 2, height: WallCopyMyShot.radius * 2))
                        var glow = c
                        glow.addFilter(.shadow(color: .yellow.opacity(0.8), radius: h * 0.025))
                        glow.stroke(Path(ellipseIn: ring), with: .color(.yellow), lineWidth: h * 0.015)
                        c.fill(Path(ellipseIn: ring), with: .radialGradient(Gradient(colors: [.yellow.opacity(0.14), .clear]),
                            center: centre, startRadius: 0, endRadius: ring.width * 0.5))
                        c.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: h * 0.003)
                        cross(at: centre, radius: h * 0.025, context: &c, tint: .yellow, width: h * 0.006)
                        if let reply = recent?.reply {
                            let p = s.point(reply)
                            var line = Path(); line.move(to: centre); line.addLine(to: p)
                            c.stroke(line, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: h * 0.004, dash: [h * 0.012]))
                            let mark = CGRect(x: p.x - h * 0.035, y: p.y - h * 0.035, width: h * 0.07, height: h * 0.07)
                            c.stroke(Path(ellipseIn: mark), with: .color(recent!.setter.other.battleTint), lineWidth: h * 0.009)
                            cross(at: p, radius: h * 0.013, context: &c, tint: .white, width: h * 0.004)
                        }
                    } else {
                        let area = s.rect(WallCopyMyShot.settingArea)
                        c.fill(Path(roundedRect: area, cornerRadius: h * 0.035), with: .color(state.player.battleTint.opacity(0.08)))
                        c.stroke(Path(roundedRect: area, cornerRadius: h * 0.035), with: .color(state.player.battleTint),
                                 style: StrokeStyle(lineWidth: h * 0.008, dash: [h * 0.035, h * 0.017]))
                    }
                }
                if target == nil && recent == nil {
                    VStack(spacing: h * 0.035) {
                        Image(systemName: "scope").font(.system(size: h * 0.14, weight: .light))
                        Text("SET YOUR SPOT").font(.system(size: h * 0.075, weight: .black, design: .rounded))
                        Text("KICK INSIDE THE OUTLINE").font(.system(size: h * 0.039, weight: .bold))
                    }.foregroundStyle(.white)
                }
                if let recent {
                    VStack { Spacer()
                        battleToast(recent.target == nil ? "TIME UP · POINT TO P\(recent.winner.rawValue)"
                            : recent.matched ? "MATCHED! · P\(recent.winner.rawValue) +1" : "NOT MATCHED · P\(recent.winner.rawValue) +1",
                                    tint: recent.winner.battleTint, height: h)
                    }
                } else if let e = state.events.last, e.kind == "set_outside_area", time - e.time < 1.5 {
                    VStack { Spacer(); battleToast("AIM INSIDE THE OUTLINE", tint: .orange, height: h) }
                }
            }.clipped()
        }
    }
    private func cross(at p: CGPoint, radius: Double, context: inout GraphicsContext, tint: Color, width: Double) {
        var path = Path()
        path.move(to: CGPoint(x: p.x - radius, y: p.y)); path.addLine(to: CGPoint(x: p.x + radius, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - radius)); path.addLine(to: CGPoint(x: p.x, y: p.y + radius))
        context.stroke(path, with: .color(tint), lineWidth: width)
    }
}

private func battleToast(_ text: String, tint: Color, height h: CGFloat) -> some View {
    Text(text).font(.system(size: h * 0.052, weight: .black, design: .rounded))
        .foregroundStyle(.white).padding(.horizontal, h * 0.035).padding(.vertical, h * 0.015)
        .background(.black.opacity(0.95), in: Capsule())
        .overlay(Capsule().stroke(tint, lineWidth: h * 0.004))
        .padding(.bottom, h * 0.015)
}

extension WallFourInRow {
    static var preview: Self {
        var s = Self()
        for column in [4, 3, 4, 5, 3, 5, 2, 6] {
            let p = Self.centre(column), t = s.readyAt + 1
            s.hit(point: p, contact: t, now: t)
        }
        return s
    }
}
extension WallTerritoryDuel {
    static var preview: Self {
        var s = Self()
        for id in [1, 9, 4, 12, 6, 13, 7, 10] {
            let t = s.readyAt + 1
            s.hit(point: Self.zones[id - 1].centre, contact: t, now: t)
        }
        return s
    }
}
extension WallCopyMyShot {
    static var preview: Self {
        var s = Self()
        s.hit(point: CGPoint(x: 1.9, y: 0.85), contact: 0, now: 0)
        return s
    }
}
#endif
