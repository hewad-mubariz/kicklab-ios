#if DEBUG
import SwiftUI

/// Power Shot analysis directions, for review only. Launch with
/// --session-design powershot-data --concept flight|bend|speed|type|session|goal|progress --shot-scene <image path>.
struct PowerShotDataConceptView: View {
    let screen: String
    let scenePath: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch screen {
            case "type": ShotTypeReveal()
            case "session": ShotSessionOverview()
            case "goal": ShotGoalMap()
            case "progress": ShotProgress()
            default: ShotReplayAnalysis(tab: screen, scenePath: scenePath)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

private enum Data {
    static let ink = Color.white
    static let muted = Color.white.opacity(0.55)
    static let panel = Color(red: 0.075, green: 0.085, blue: 0.085)
    static let line = Color.white.opacity(0.1)
    static func display(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .title) }
}

private struct ShotLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(Data.muted)
    }
}

private struct ShotTopBar: View {
    var title = "SHOT 03"
    var body: some View {
        HStack {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44).glassEffect(.regular, in: .circle)
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(shotLime).frame(width: 7, height: 7)
                Text(title).font(.system(size: 13, weight: .bold)).tracking(0.8)
            }
            .padding(.horizontal, 14).frame(height: 34).glassEffect(.regular, in: .capsule)
            Spacer()
            Image(systemName: "arrow.down").font(.system(size: 17, weight: .bold))
                .foregroundStyle(TrainingHomeStyle.buttonInk)
                .frame(width: 44, height: 44).background(shotLime, in: .circle)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - In the replay

/// The replay with one analysis panel under it: speed, four numbers, and three graphs.
private struct ShotReplayAnalysis: View {
    let tab: String
    let scenePath: String?

    var body: some View {
        VStack(spacing: 0) {
            ShotTopBar().padding(.top, 58)
            video.padding(.top, 12)
            VStack(spacing: 14) {
                headline
                stats
                tabs
                graph.frame(height: 172)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    private var video: some View {
        GeometryReader { geometry in
            let shot = ShotPath(size: geometry.size,
                                points: [CGPoint(x: 0.26, y: 1.02), CGPoint(x: 0.8, y: 0.8),
                                         CGPoint(x: 0.8, y: 0.42), CGPoint(x: 0.6, y: 0.395)],
                                ballScale: 0.08)
            ZStack {
                ShotScene(path: scenePath, zoom: 1.7, anchorY: 0.47, shift: -0.06)
                Canvas { context, _ in ShotEffects.tracer(context, shot, head: 1) }
            }
            .clipShape(.rect(cornerRadius: 24))
        }
        .frame(height: 286)
        .padding(.horizontal, 12)
    }

    private var headline: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ShotLabel(text: "LAUNCH SPEED")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("94").font(Data.display(76))
                    Text("KM/H").font(Data.display(24)).foregroundStyle(Data.muted)
                }
                .padding(.top, 10)
                .frame(height: 64)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("CURLER").font(Data.display(22)).padding(.top, 3)
                    .foregroundStyle(TrainingHomeStyle.buttonInk)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(shotLime, in: .capsule)
                Text("Best today: 104 km/h").font(.caption).foregroundStyle(Data.muted)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat("BEND", "1.8 m", "curls left")
            stat("HEIGHT", "2.5 m", "at 12 m")
            stat("FLIGHT", "0.82 s", "to the goal")
            stat("ANGLE", "21°", "launch")
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Data.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Data.line).frame(height: 1) }
    }

    private func stat(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ShotLabel(text: title)
            Text(value).font(Data.display(26)).padding(.top, 2)
            Text(note).font(.system(size: 10)).foregroundStyle(Data.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(["Flight", "Bend", "Speed"], id: \.self) { name in
                let selected = name.lowercased() == tab
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? TrainingHomeStyle.buttonInk : Data.muted)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background { if selected { Capsule().fill(shotLime) } }
            }
        }
        .padding(3)
        .background(Data.panel, in: .capsule)
        .overlay { Capsule().strokeBorder(Data.line) }
    }

    @ViewBuilder private var graph: some View {
        switch tab {
        case "bend": BendGraph()
        case "speed": SpeedGraph()
        default: FlightGraph()
        }
    }
}

/// Side view: height over distance, the crossbar at the end.
private struct FlightGraph: View {
    var body: some View {
        Canvas { c, size in
            let left: CGFloat = 26, bottom: CGFloat = 22, right: CGFloat = 10, top: CGFloat = 10
            let w = size.width - left - right, h = size.height - bottom - top
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: left + w * x / 20, y: top + h * (1 - y / 3)) }
            for y in [1.0, 2.0, 3.0] {
                var grid = Path(); grid.move(to: pt(0, y)); grid.addLine(to: pt(20, y))
                c.stroke(grid, with: .color(Data.line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                c.draw(Text("\(Int(y)) m").font(.system(size: 9)).foregroundColor(Data.muted), at: CGPoint(x: 10, y: pt(0, y).y))
            }
            for x in [0.0, 5, 10, 15, 20] {
                c.draw(Text("\(Int(x))").font(.system(size: 9)).foregroundColor(Data.muted), at: CGPoint(x: pt(x, 0).x, y: size.height - 8))
            }
            var ground = Path(); ground.move(to: pt(0, 0)); ground.addLine(to: pt(20, 0))
            c.stroke(ground, with: .color(.white.opacity(0.35)), lineWidth: 1.2)
            // The goal at 18 m, crossbar 2.44 m.
            var goal = Path(); goal.move(to: pt(18, 0)); goal.addLine(to: pt(18, 2.44)); goal.addLine(to: pt(19.4, 2.44))
            c.stroke(goal, with: .color(.white.opacity(0.75)), lineWidth: 2)
            var net = Path(); net.move(to: pt(19.4, 2.44)); net.addLine(to: pt(20, 0))
            c.stroke(net, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            func height(_ x: Double) -> Double { 2.5 - 0.0153 * (x - 12.5) * (x - 12.5) }
            var arc = Path(), fill = Path()
            fill.move(to: pt(0, 0))
            for i in 0...90 {
                let x = 18 * Double(i) / 90, p = pt(x, max(0.11, height(x)))
                i == 0 ? arc.move(to: p) : arc.addLine(to: p)
                fill.addLine(to: p)
            }
            fill.addLine(to: pt(18, 0)); fill.closeSubpath()
            c.fill(fill, with: .linearGradient(Gradient(colors: [shotLime.opacity(0.28), shotLime.opacity(0)]),
                                                startPoint: pt(0, 2.5), endPoint: pt(0, 0)))
            c.drawLayer { l in l.addFilter(.blur(radius: 5)); l.stroke(arc, with: .color(shotLime.opacity(0.7)), lineWidth: 5) }
            c.stroke(arc, with: .color(shotLime), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            // Apex and launch angle.
            let apex = pt(12.5, 2.5)
            c.fill(Path(ellipseIn: CGRect(x: apex.x - 4.5, y: apex.y - 4.5, width: 9, height: 9)), with: .color(.white))
            c.draw(Text("2.5 m").font(.system(size: 11, weight: .bold)).foregroundColor(.white), at: CGPoint(x: apex.x, y: apex.y - 13))
            var angle = Path()
            angle.addArc(center: pt(0, 0.11), radius: 30, startAngle: .degrees(0), endAngle: .degrees(-21), clockwise: true)
            c.stroke(angle, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
            c.draw(Text("21°").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: pt(0, 0).x + 48, y: pt(0, 0).y - 9))
            let entry = pt(18, height(18))
            c.fill(Path(ellipseIn: CGRect(x: entry.x - 6, y: entry.y - 6, width: 12, height: 12)), with: .color(shotLime))
            c.draw(Text("top corner").font(.system(size: 10, weight: .semibold)).foregroundColor(shotLime), at: CGPoint(x: entry.x - 36, y: entry.y + 14))
        }
        .padding(10)
        .background(Data.panel, in: .rect(cornerRadius: 18))
    }
}

/// From above: the straight line to the target and how far the shot bent away from it.
private struct BendGraph: View {
    var body: some View {
        VStack(spacing: 8) {
            Canvas { c, size in
                let left: CGFloat = 26, midY = size.height / 2
                let scale = min((size.width - 40) / 19, size.height / 8.2)
                // Seen from above with the goal to the right; your right-hand side is down.
                func pt(_ lateral: Double, _ forward: Double) -> CGPoint {
                    CGPoint(x: left + forward * scale, y: midY + lateral * scale)
                }
                // Goal mouth at 18 m.
                var goal = Path(); goal.move(to: pt(-3.66, 18)); goal.addLine(to: pt(3.66, 18))
                c.stroke(goal, with: .color(.white.opacity(0.85)), lineWidth: 3)
                for post in [-3.66, 3.66] {
                    let p = pt(post, 18)
                    c.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
                }
                var box = Path(); box.move(to: pt(-6, 18)); box.addLine(to: pt(-6, 12.5)); box.addLine(to: pt(6, 12.5)); box.addLine(to: pt(6, 18))
                c.stroke(box, with: .color(.white.opacity(0.18)), lineWidth: 1)
                let end = (lateral: 2.9, forward: 18.0)
                var chord = Path(); chord.move(to: pt(0, 0)); chord.addLine(to: pt(end.lateral, end.forward))
                c.stroke(chord, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                func lateral(_ f: Double) -> Double { end.lateral * f / 18 + 1.8 * sin(.pi * pow(f / 18, 0.85)) }
                var path = Path(), area = Path()
                area.move(to: pt(0, 0))
                for i in 0...90 {
                    let f = 18 * Double(i) / 90, p = pt(lateral(f), f)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                    area.addLine(to: p)
                }
                area.addLine(to: pt(0, 0)); area.closeSubpath()
                c.fill(area, with: .color(shotLime.opacity(0.14)))
                c.drawLayer { l in l.addFilter(.blur(radius: 5)); l.stroke(path, with: .color(shotLime.opacity(0.7)), lineWidth: 5) }
                c.stroke(path, with: .color(shotLime), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                // The widest point.
                let f = 10.2, onPath = pt(lateral(f), f), onChord = pt(end.lateral * f / 18, f)
                var gap = Path(); gap.move(to: onChord); gap.addLine(to: onPath)
                c.stroke(gap, with: .color(.white), lineWidth: 1.6)
                for p in [onChord, onPath] { c.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white)) }
                c.draw(Text("1.8 m").font(.system(size: 12, weight: .bold)).foregroundColor(.white), at: CGPoint(x: onPath.x + 24, y: (onPath.y + onChord.y) / 2))
                let spot = pt(0, 0)
                c.fill(Path(ellipseIn: CGRect(x: spot.x - 5, y: spot.y - 5, width: 10, height: 10)), with: .color(.white))
                c.draw(Text("you").font(.system(size: 10)).foregroundColor(Data.muted), at: CGPoint(x: spot.x, y: spot.y - 13))
            }
            HStack(spacing: 4) {
                ForEach(["Straight", "Slight", "Strong", "Banana"], id: \.self) { level in
                    Text(level).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(level == "Banana" ? TrainingHomeStyle.buttonInk : Data.muted)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background(level == "Banana" ? shotLime : Data.line, in: .capsule)
                }
            }
        }
        .padding(10)
        .background(Data.panel, in: .rect(cornerRadius: 18))
    }
}

/// Speed through the flight, from the foot to the goal.
private struct SpeedGraph: View {
    var body: some View {
        Canvas { c, size in
            let left: CGFloat = 30, bottom: CGFloat = 20, right: CGFloat = 12, top: CGFloat = 22
            let w = size.width - left - right, h = size.height - bottom - top
            func pt(_ t: Double, _ v: Double) -> CGPoint { CGPoint(x: left + w * t / 0.82, y: top + h * (1 - (v - 60) / 40)) }
            for v in [60.0, 70, 80, 90, 100] {
                var grid = Path(); grid.move(to: pt(0, v)); grid.addLine(to: pt(0.82, v))
                c.stroke(grid, with: .color(Data.line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                c.draw(Text("\(Int(v))").font(.system(size: 9)).foregroundColor(Data.muted), at: CGPoint(x: 12, y: pt(0, v).y))
            }
            for t in [0.0, 0.2, 0.4, 0.6, 0.8] {
                c.draw(Text(String(format: "%.1fs", t)).font(.system(size: 9)).foregroundColor(Data.muted), at: CGPoint(x: pt(t, 60).x, y: size.height - 7))
            }
            func speed(_ t: Double) -> Double { 94 * exp(-0.34 * t) }
            var line = Path(), fill = Path()
            fill.move(to: pt(0, 60))
            for i in 0...80 {
                let t = 0.82 * Double(i) / 80, p = pt(t, speed(t))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
                fill.addLine(to: p)
            }
            fill.addLine(to: pt(0.82, 60)); fill.closeSubpath()
            c.fill(fill, with: .linearGradient(Gradient(colors: [shotLime.opacity(0.3), shotLime.opacity(0)]),
                                                startPoint: pt(0, 94), endPoint: pt(0, 60)))
            c.drawLayer { l in l.addFilter(.blur(radius: 5)); l.stroke(line, with: .color(shotLime.opacity(0.7)), lineWidth: 5) }
            c.stroke(line, with: .color(shotLime), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            for (t, label) in [(0.0, "94 launch"), (0.82, "71 at goal")] {
                let p = pt(t, speed(t))
                c.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)), with: .color(.white))
                c.draw(Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                       at: CGPoint(x: p.x + (t == 0 ? 34 : -30), y: p.y - 13))
            }
            c.draw(Text("Kept 76% of its speed").font(.system(size: 11, weight: .semibold)).foregroundColor(shotLime),
                   at: CGPoint(x: left + w * 0.62, y: top + h * 0.15))
        }
        .padding(10)
        .background(Data.panel, in: .rect(cornerRadius: 18))
    }
}

// MARK: - After the shot

private enum ShotKind: String, CaseIterable {
    case rocket, curler, knuckleball, chip, dipper, driven
    var title: String { rawValue.uppercased() }
}

/// A small drawing of each shot type's flight.
private struct ShotKindIcon: View {
    let kind: ShotKind
    var color: Color = shotLime

    var body: some View {
        Canvas { c, size in
            let w = size.width, h = size.height
            var p = Path()
            switch kind {
            case .rocket:
                p.move(to: CGPoint(x: 0.12 * w, y: 0.8 * h)); p.addLine(to: CGPoint(x: 0.88 * w, y: 0.2 * h))
            case .curler:
                p.move(to: CGPoint(x: 0.2 * w, y: 0.88 * h))
                p.addCurve(to: CGPoint(x: 0.42 * w, y: 0.12 * h), control1: CGPoint(x: 1.0 * w, y: 0.7 * h), control2: CGPoint(x: 0.95 * w, y: 0.15 * h))
            case .knuckleball:
                p.move(to: CGPoint(x: 0.1 * w, y: 0.82 * h))
                for i in 1...6 {
                    let x = 0.1 + 0.8 * Double(i) / 6, y = 0.82 - 0.6 * Double(i) / 6 + (i % 2 == 0 ? 0.1 : -0.1)
                    p.addLine(to: CGPoint(x: x * w, y: y * h))
                }
            case .chip:
                p.move(to: CGPoint(x: 0.1 * w, y: 0.85 * h))
                p.addQuadCurve(to: CGPoint(x: 0.9 * w, y: 0.75 * h), control: CGPoint(x: 0.5 * w, y: -0.45 * h))
            case .dipper:
                p.move(to: CGPoint(x: 0.08 * w, y: 0.82 * h))
                p.addQuadCurve(to: CGPoint(x: 0.66 * w, y: 0.2 * h), control: CGPoint(x: 0.3 * w, y: 0.2 * h))
                p.addQuadCurve(to: CGPoint(x: 0.86 * w, y: 0.9 * h), control: CGPoint(x: 0.86 * w, y: 0.2 * h))
            case .driven:
                p.move(to: CGPoint(x: 0.1 * w, y: 0.7 * h)); p.addLine(to: CGPoint(x: 0.9 * w, y: 0.6 * h))
            }
            c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(2.6, w * 0.035), lineCap: .round, lineJoin: .round))
            if let end = p.currentPoint {
                let r = max(3, w * 0.06)
                c.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
    }
}

/// The moment after the strike: the shot is named, measured against your best, and collected.
private struct ShotTypeReveal: View {
    private let collected: Set<ShotKind> = [.rocket, .curler, .dipper]

    var body: some View {
        VStack(spacing: 0) {
            ShotTopBar().padding(.top, 58)
            Text("NEW SHOT TYPE").font(.system(size: 12, weight: .heavy)).tracking(2).foregroundStyle(shotLime)
                .padding(.top, 26)
            ZStack {
                Circle().fill(shotLime.opacity(0.12)).frame(width: 230, height: 230).blur(radius: 30)
                ShotKindIcon(kind: .curler).frame(width: 150, height: 150)
                    .shadow(color: shotLime.opacity(0.8), radius: 10)
            }
            .frame(height: 190)
            Text("CURLER").font(Data.display(84)).frame(height: 76)
            Text("Big bend at speed. It curled 1.8 m into the top corner.")
                .font(.subheadline).foregroundStyle(Data.muted)
                .multilineTextAlignment(.center).padding(.horizontal, 40).padding(.top, 4)
            VStack(spacing: 12) {
                bar("POWER", "94 km/h", 0.78, best: 0.86)
                bar("BEND", "1.8 m", 0.9, best: 0.9)
                bar("HEIGHT", "2.5 m", 0.62, best: 0.74)
            }
            .padding(16)
            .background(Data.panel, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 18).padding(.top, 22)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ShotLabel(text: "SHOT TYPES COLLECTED")
                    Spacer()
                    Text("3 of 6").font(.caption.weight(.bold)).foregroundStyle(shotLime)
                }
                HStack(spacing: 8) {
                    ForEach(ShotKind.allCases, id: \.self) { kind in
                        let have = collected.contains(kind)
                        VStack(spacing: 4) {
                            ShotKindIcon(kind: kind, color: have ? shotLime : .white.opacity(0.22)).frame(width: 30, height: 30)
                            Text(kind == .knuckleball ? "KNUCKLE" : kind.title)
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(have ? .white : Data.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .background(Data.panel, in: .rect(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(kind == .curler ? shotLime : Data.line, lineWidth: kind == .curler ? 1.5 : 1) }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 18)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    private func bar(_ title: String, _ value: String, _ amount: CGFloat, best: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ShotLabel(text: title)
                Spacer()
                Text(value).font(Data.display(20))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Data.line)
                    Capsule().fill(shotLime).frame(width: geometry.size.width * amount)
                    Rectangle().fill(.white).frame(width: 2, height: 14).offset(x: geometry.size.width * best - 1)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Across sessions

private struct ShotSessionOverview: View {
    private let shots: [(number: Int, speed: Int, bend: Double, kind: String)] = [
        (1, 82, 0.4, "Driven"), (2, 94, 1.8, "Curler"), (3, 88, 1.1, "Curler"), (4, 104, 0.2, "Rocket"),
        (5, 79, 0.9, "Dipper"), (6, 91, -0.6, "Driven"), (7, 86, 1.4, "Curler"), (8, 97, 0.3, "Rocket")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShotTopBar(title: "SESSION").padding(.top, 58)
            Text("8 SHOTS").font(Data.display(44)).padding(.top, 18).padding(.horizontal, 20)
            HStack(spacing: 10) {
                summary("BEST", "104", "km/h")
                summary("AVERAGE", "90", "km/h")
                consistency
            }
            .padding(.horizontal, 18).padding(.top, 8)
            pitch.frame(height: 300).padding(.horizontal, 18).padding(.top, 14)
            VStack(spacing: 6) {
                ForEach(shots.sorted { $0.speed > $1.speed }.prefix(3), id: \.number) { shot in
                    HStack {
                        Text(String(format: "%02d", shot.number)).font(Data.display(20)).foregroundStyle(Data.muted).frame(width: 30, alignment: .leading)
                        Text(shot.kind).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(shot.speed) km/h").font(Data.display(22))
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(shot.speed == 104 ? shotLime.opacity(0.14) : Data.panel, in: .rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(shot.speed == 104 ? shotLime.opacity(0.7) : Data.line) }
                }
            }
            .padding(.horizontal, 18).padding(.top, 14)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    private func summary(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ShotLabel(text: title)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Data.display(34))
                Text(unit).font(.caption2).foregroundStyle(Data.muted)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 76)
        .background(Data.panel, in: .rect(cornerRadius: 16))
    }

    private var consistency: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShotLabel(text: "STEADY")
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Data.line, lineWidth: 4)
                    Circle().trim(from: 0, to: 0.84).stroke(shotLime, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                Text("84%").font(Data.display(30))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 76)
        .background(Data.panel, in: .rect(cornerRadius: 16))
    }

    /// Every shot from above, the best one lit.
    private var pitch: some View {
        Canvas { c, size in
            let midX = size.width / 2, top: CGFloat = 44, bottom = size.height - 18
            let scale = (bottom - top) / 18
            func pt(_ lateral: Double, _ forward: Double) -> CGPoint { CGPoint(x: midX + lateral * scale * 1.3, y: bottom - forward * scale) }
            var box = Path(); box.move(to: pt(-7, 18)); box.addLine(to: pt(-7, 12.5)); box.addLine(to: pt(7, 12.5)); box.addLine(to: pt(7, 18))
            box.move(to: pt(-3, 18)); box.addLine(to: pt(-3, 16.2)); box.addLine(to: pt(3, 16.2)); box.addLine(to: pt(3, 18))
            c.stroke(box, with: .color(.white.opacity(0.2)), lineWidth: 1)
            var goal = Path(); goal.move(to: pt(-3.66, 18)); goal.addLine(to: pt(3.66, 18))
            c.stroke(goal, with: .color(.white.opacity(0.85)), lineWidth: 3)
            let ends: [Double] = [-1.2, 2.9, 1.6, -0.4, 3.4, -2.6, 2.2, 0.8]
            for (index, shot) in shots.enumerated() {
                let end = ends[index], best = shot.speed == 104
                var path = Path()
                for i in 0...60 {
                    let f = 18 * Double(i) / 60
                    let lateral = end * f / 18 + shot.bend * sin(.pi * pow(f / 18, 0.85))
                    i == 0 ? path.move(to: pt(lateral, f)) : path.addLine(to: pt(lateral, f))
                }
                if best { c.drawLayer { l in l.addFilter(.blur(radius: 5)); l.stroke(path, with: .color(shotLime.opacity(0.8)), lineWidth: 5) } }
                c.stroke(path, with: .color(best ? shotLime : .white.opacity(0.32)), style: StrokeStyle(lineWidth: best ? 2.6 : 1.4, lineCap: .round))
                let tip = pt(end, 18)
                c.fill(Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)), with: .color(best ? shotLime : .white.opacity(0.6)))
            }
            let spot = pt(0, 0)
            c.fill(Path(ellipseIn: CGRect(x: spot.x - 5, y: spot.y - 5, width: 10, height: 10)), with: .color(.white))
        }
        .background(Color(red: 0.06, green: 0.16, blue: 0.08), in: .rect(cornerRadius: 20))
        .overlay(alignment: .topLeading) {
            ShotLabel(text: "EVERY SHOT FROM ABOVE").padding(12)
        }
    }
}

/// Where each shot crossed the goal line, seen from the front.
private struct ShotGoalMap: View {
    private let hits: [(x: Double, y: Double, speed: Int)] = [
        (6.7, 2.1, 94), (6.4, 1.9, 88), (0.6, 2.05, 97), (3.4, 0.5, 79), (5.6, 0.7, 91), (1.4, 1.2, 86)
    ]
    private let misses: [(x: Double, y: Double)] = [(4.6, 2.9), (7.7, 0.9)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShotTopBar(title: "SESSION").padding(.top, 58)
            Text("WHERE IT WENT").font(Data.display(44)).padding(.top, 18).padding(.horizontal, 20)
            Text("Seen from behind the goal line. Bigger and brighter means faster.")
                .font(.subheadline).foregroundStyle(Data.muted).padding(.horizontal, 20)
            goal.frame(height: 250).padding(.horizontal, 12).padding(.top, 26)
            HStack(spacing: 10) {
                card("ON TARGET", "6/8")
                card("TOP CORNERS", "3")
                card("FAVOURITE", "Top right")
            }
            .padding(.horizontal, 18).padding(.top, 18)
            HStack(spacing: 10) {
                Image(systemName: "scope").foregroundStyle(shotLime)
                Text("Challenge: hit both top corners in one session").font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(14)
            .background(shotLime.opacity(0.1), in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(shotLime.opacity(0.5)) }
            .padding(.horizontal, 18).padding(.top, 14)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    private func card(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ShotLabel(text: title)
            Text(value).font(Data.display(26)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 70)
        .background(Data.panel, in: .rect(cornerRadius: 14))
    }

    private var goal: some View {
        Canvas { c, size in
            let left: CGFloat = 24, scale = (size.width - 48) / 7.32, base = size.height - 30
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: left + x * scale, y: base - y * scale) }
            // Net.
            var net = Path()
            for i in 1..<15 { let x = 7.32 * Double(i) / 15; net.move(to: pt(x, 0)); net.addLine(to: pt(x, 2.44)) }
            for i in 1..<5 { let y = 2.44 * Double(i) / 5; net.move(to: pt(0, y)); net.addLine(to: pt(7.32, y)) }
            c.stroke(net, with: .color(.white.opacity(0.1)), lineWidth: 1)
            // Top corners.
            for x in [0.0, 5.82] {
                c.fill(Path(roundedRect: CGRect(origin: pt(x, 2.44), size: CGSize(width: 1.5 * scale, height: 0.9 * scale)), cornerRadius: 6),
                       with: .color(shotLime.opacity(0.1)))
            }
            var frame = Path(); frame.move(to: pt(0, 0)); frame.addLine(to: pt(0, 2.44)); frame.addLine(to: pt(7.32, 2.44)); frame.addLine(to: pt(7.32, 0))
            c.stroke(frame, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            var ground = Path(); ground.move(to: pt(-0.5, 0)); ground.addLine(to: pt(7.82, 0))
            c.stroke(ground, with: .color(.white.opacity(0.3)), lineWidth: 1)
            for hit in hits {
                let p = pt(hit.x, hit.y), r = 5 + CGFloat(hit.speed - 75) * 0.45, fast = hit.speed >= 90
                if fast { c.drawLayer { l in l.addFilter(.blur(radius: 6)); l.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(shotLime)) } }
                c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(fast ? shotLime : .white.opacity(0.65)))
                c.draw(Text("\(hit.speed)").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.85)), at: CGPoint(x: p.x, y: p.y + r + 8))
            }
            for miss in misses {
                let p = pt(miss.x, miss.y)
                var x = Path(); x.move(to: CGPoint(x: p.x - 6, y: p.y - 6)); x.addLine(to: CGPoint(x: p.x + 6, y: p.y + 6))
                x.move(to: CGPoint(x: p.x + 6, y: p.y - 6)); x.addLine(to: CGPoint(x: p.x - 6, y: p.y + 6))
                c.stroke(x, with: .color(Color(red: 1, green: 0.45, blue: 0.42)), lineWidth: 2.4)
            }
        }
    }
}

/// Fastest shot per session over time, tied to the leaderboard.
private struct ShotProgress: View {
    private let sessions: [(label: String, speed: Int)] = [
        ("12 Sep", 78), ("16 Sep", 81), ("19 Sep", 85), ("23 Sep", 84), ("26 Sep", 90), ("30 Sep", 93), ("4 Oct", 97), ("Today", 104)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShotTopBar(title: "POWER SHOT").padding(.top, 58)
            ShotLabel(text: "FASTEST SHOT").padding(.top, 22).padding(.bottom, 10).padding(.horizontal, 20)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("104").font(Data.display(96))
                Text("KM/H").font(Data.display(28)).foregroundStyle(Data.muted)
                Spacer()
                Text("NEW BEST").font(Data.display(20)).padding(.top, 3)
                    .foregroundStyle(TrainingHomeStyle.buttonInk)
                    .padding(.horizontal, 12).frame(height: 30).background(shotLime, in: .capsule)
            }
            .padding(.horizontal, 20).padding(.top, 14).frame(height: 96)
            Text("+26 km/h since your first session").font(.subheadline).foregroundStyle(shotLime).padding(.horizontal, 20)
            chart.frame(height: 270).padding(.horizontal, 18).padding(.top, 20)
            HStack(spacing: 12) {
                Image(systemName: "trophy").font(.system(size: 18, weight: .medium)).foregroundStyle(shotLime)
                    .frame(width: 40, height: 40).background(shotLime.opacity(0.1), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("#12 fastest shot this week").font(.subheadline.weight(.semibold))
                    Text("Power Shot leaderboard · Global").font(.caption).foregroundStyle(Data.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Data.muted)
            }
            .padding(14)
            .background(Data.panel, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 18).padding(.top, 16)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    private var chart: some View {
        Canvas { c, size in
            let bottom = size.height - 22, top: CGFloat = 14, gap: CGFloat = 10
            let barWidth = (size.width - gap * CGFloat(sessions.count - 1)) / CGFloat(sessions.count)
            func y(_ v: Int) -> CGFloat { bottom - (bottom - top) * CGFloat(v - 60) / 50 }
            for (index, session) in sessions.enumerated() {
                let x = CGFloat(index) * (barWidth + gap), last = index == sessions.count - 1
                let bar = Path(roundedRect: CGRect(x: x, y: y(session.speed), width: barWidth, height: bottom - y(session.speed)),
                               cornerRadii: RectangleCornerRadii(topLeading: 8, topTrailing: 8))
                if last { c.drawLayer { l in l.addFilter(.blur(radius: 8)); l.fill(bar, with: .color(shotLime.opacity(0.6))) } }
                c.fill(bar, with: last ? .color(shotLime) : .color(.white.opacity(0.16)))
                c.draw(Text("\(session.speed)").font(.system(size: 11, weight: .bold)).foregroundColor(last ? shotLime : .white.opacity(0.8)),
                       at: CGPoint(x: x + barWidth / 2, y: y(session.speed) - 10))
                c.draw(Text(session.label).font(.system(size: 8)).foregroundColor(Data.muted), at: CGPoint(x: x + barWidth / 2, y: size.height - 8))
            }
        }
        .padding(14)
        .background(Data.panel, in: .rect(cornerRadius: 20))
    }
}
#endif
