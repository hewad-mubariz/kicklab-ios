#if WALL_GAMES_PREVIEW
import SwiftUI

/// Explicit first-release catalogue. Goal Duel, the experimental 3D keeper and
/// Find the Space remain available in the research build, not in this menu.
struct WallArcadeGame: Identifiable {
    let game: WallGame?
    var id: String { game?.rawValue ?? "top-bins" }
    var title: String { game?.title ?? "Top Bins" }
    var subtitle: String { game?.subtitle ?? "Find the corners. Make all five count." }
    var instructions: String { game?.instructions ?? "Five shots at the goal corners. Upper rings score 100; lower rings score 50." }
    var twoPlayers: Bool { game?.isParty == true }
    static let all: [Self] = [.init(game: .brickBlast), .init(game: .clearTheWall),
        .init(game: .memoryStrike), .init(game: .meteorDefence), .init(game: nil),
        .init(game: .crossCircle), .init(game: .fourInRow),
        .init(game: .territoryDuel), .init(game: .copyMyShot)]
}

enum WallArcadeStyle {
    static let background = TrainingHomeStyle.background(.dark)
    static let panel = TrainingHomeStyle.panel(.dark)
    static let lime = TrainingHomeStyle.lime
    static let cyan = Color(red: 0.1, green: 0.84, blue: 1)
    static let coral = Color(red: 1, green: 0.38, blue: 0.29)
    static let gold = Color(red: 1, green: 0.79, blue: 0.2)
    static func display(_ size: CGFloat) -> Font { TrainingHomeStyle.display(size, relativeTo: .title) }
}

/// Menu cards reuse captured frames of the real game renderer. No animation
/// clock, shader work or 3D scene runs while browsing or exporting a result.
struct WallArcadeArtwork: View {
    let game: WallGame?
    private var asset: String? {
        guard let game, game != .clearTheWall else { return nil }
        return "arcade-" + game.rawValue.replacingOccurrences(of:"-v1",with:"")
    }
    var body: some View {
        Group {
            if let asset {
                GeometryReader { g in
                    Image(asset).resizable().scaledToFill()
                        .frame(width:g.size.width,height:g.size.height)
                        .scaleEffect(1.30)
                        .clipped()
                }
            } else { drawnArtwork }
        }.accessibilityHidden(true)
    }
    private var drawnArtwork: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let cyan = WallArcadeStyle.cyan, coral = WallArcadeStyle.coral, gold = WallArcadeStyle.gold
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.025, green: 0.10, blue: 0.15), .black]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x*w, y: y*h) }
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x*w, y: y*h, width: width*w, height: height*h)
            }
            func tile(_ r: CGRect, _ tint: Color, radius: CGFloat = 4) {
                let shadow = r.offsetBy(dx: h*0.018, dy: h*0.025)
                context.fill(Path(roundedRect: shadow, cornerRadius: radius), with: .color(tint.opacity(0.35)))
                let path = Path(roundedRect: r, cornerRadius: radius)
                context.fill(path, with: .linearGradient(Gradient(colors: [tint, tint.opacity(0.4)]), startPoint: r.origin, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
                context.stroke(path, with: .color(tint.opacity(0.95)), lineWidth: 1.5)
                var edge = Path(); edge.move(to: CGPoint(x:r.minX+3,y:r.minY+2)); edge.addLine(to:CGPoint(x:r.maxX-3,y:r.minY+2))
                context.stroke(edge, with:.color(.white.opacity(0.55)), lineWidth:1)
            }
            func glyph(_ text: String, _ p: CGPoint, _ color: Color, _ fontSize: CGFloat) {
                context.draw(Text(text).font(.system(size:fontSize,weight:.black,design:.rounded)).foregroundStyle(color), at:p)
            }
            func symbol(_ name: String, _ p: CGPoint, _ color: Color, _ fontSize: CGFloat) {
                var image = context.resolve(Image(systemName:name))
                image.shading = .color(color)
                context.draw(image, in:CGRect(x:p.x-fontSize/2,y:p.y-fontSize/2,width:fontSize,height:fontSize))
            }
            switch game {
            case .brickBlast:
                for (row, count) in [3,5,7,6].enumerated() {
                    for col in 0..<count {
                        let x = (1-CGFloat(count)*0.112)/2+CGFloat(col)*0.112
                        let y = 0.12+CGFloat(row)*0.16
                        let colors = [coral,gold,cyan]
                        let r = rect(x,y,0.105,0.145)
                        tile(r,colors[(col+row*2)%3],radius:3)
                        var crack=Path();crack.move(to:CGPoint(x:r.midX,y:r.minY));crack.addLine(to:CGPoint(x:r.midX-4,y:r.midY));crack.addLine(to:CGPoint(x:r.midX+3,y:r.midY+5))
                        context.stroke(crack,with:.color(.black.opacity(0.3)),lineWidth:1)
                    }
                }
                for i in 0..<11 {
                    let x=0.25+CGFloat(i)*0.05, y=0.80+CGFloat(i%3)*0.035
                    tile(rect(x,y,0.018,0.03),[cyan,gold,coral][i%3],radius:1)
                }
            case .memoryStrike:
                for i in 0..<4 {
                    let x=0.23+CGFloat(i%2)*0.29, y=0.14+CGFloat(i/2)*0.37
                    let color=[cyan,coral,gold,Color.purple][i]
                    tile(rect(x,y,0.25,0.31),color.opacity(0.6),radius:6)
                    symbol(["star.fill","moon.fill","sun.max.fill","diamond.fill"][i],point(x+0.125,y+0.155),color,h*0.19)
                }
            case .crossCircle:
                for i in 0..<9 {
                    let x=0.26+CGFloat(i%3)*0.165,y=0.12+CGFloat(i/3)*0.25
                    context.stroke(Path(rect(x,y,0.16,0.24)),with:.color(cyan.opacity(0.6)),lineWidth:1.5)
                    if [0,4,8].contains(i) { glyph("×",point(x+0.08,y+0.12),cyan,h*0.25) }
                    if [1,6].contains(i) { glyph("○",point(x+0.08,y+0.12),coral,h*0.22) }
                }
            case .fourInRow:
                tile(rect(0.17,0.12,0.66,0.73),Color.blue.opacity(0.65))
                for row in 0..<5 { for col in 0..<7 {
                    let p=point(0.22+CGFloat(col)*0.092,0.21+CGFloat(row)*0.135)
                    let r=CGRect(x:p.x-h*0.048,y:p.y-h*0.048,width:h*0.096,height:h*0.096)
                    let c:Color = row>2 || (col==3 && row>0) ? ((row+col)%3==0 ? coral:cyan):.black
                    context.fill(Path(ellipseIn:r),with:.color(c));context.stroke(Path(ellipseIn:r),with:.color(cyan.opacity(0.6)),lineWidth:1)
                }}
            case .meteorDefence:
                for i in 0..<16 {
                    let height=0.10+CGFloat((i*7)%6)*0.028
                    tile(rect(CGFloat(i)/16,0.93-height,0.045,height),cyan.opacity(0.5),radius:0)
                }
                for i in 0..<4 {
                    let p=point(0.18+CGFloat(i)*0.22,0.28+CGFloat(i%2)*0.2)
                    var tail=Path();tail.move(to:CGPoint(x:p.x-h*0.13,y:p.y-h*0.26));tail.addLine(to:p)
                    context.stroke(tail,with:.linearGradient(Gradient(colors:[coral.opacity(0.1),gold]),startPoint:CGPoint(x:p.x,y:p.y-h*0.2),endPoint:p),style:StrokeStyle(lineWidth:h*0.055,lineCap:.round))
                    context.fill(Path(ellipseIn:CGRect(x:p.x-h*0.055,y:p.y-h*0.055,width:h*0.11,height:h*0.11)),with:.color(coral))
                    context.stroke(Path(ellipseIn:CGRect(x:p.x-h*0.055,y:p.y-h*0.055,width:h*0.11,height:h*0.11)),with:.color(gold),lineWidth:3)
                }
            case .territoryDuel:
                for i in 0..<11 {
                    let p=point(0.18+CGFloat(i%4)*0.20+(i/4%2==0 ? 0:0.04),0.24+CGFloat(i/4)*0.25)
                    var hex=Path()
                    for v in 0..<6 {
                        let a=Double(v)*Double.pi/3
                        let vertex=CGPoint(x:p.x+cos(a)*h*0.14,y:p.y+sin(a)*h*0.14)
                        if v==0 { hex.move(to:vertex) } else { hex.addLine(to:vertex) }
                    }
                    hex.closeSubpath();let c=i%3==0 ? coral:cyan
                    context.fill(hex,with:.color(c.opacity(0.55)));context.stroke(hex,with:.color(c),lineWidth:2)
                }
            case .copyMyShot:
                for i in 0..<2 {
                    let p=point(i==0 ? 0.31:0.65,i==0 ? 0.66:0.35), r=h*(i==0 ? 0.09:0.19)
                    context.stroke(Path(ellipseIn:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r)),with:.color(i==0 ? cyan:gold),lineWidth:3)
                    glyph("+",p,i==0 ? cyan:gold,r)
                }
            case .clearTheWall:
                for i in 0..<6 {
                    let x=0.15+CGFloat(i%3)*0.24,y=0.16+CGFloat(i/3)*0.35
                    tile(rect(x,y,0.22,0.30),i==1 || i==3 ? gold:cyan.opacity(0.6))
                    glyph(i==1 || i==3 ? "✓":"\(i+1)",point(x+0.11,y+0.15),.white,h*0.18)
                }
            case .goalDuel, .none:
                let r=rect(0.12,0.18,0.76,0.64)
                for i in 0...12 {
                    var p=Path();p.move(to:CGPoint(x:r.minX+r.width*CGFloat(i)/12,y:r.minY));p.addLine(to:CGPoint(x:r.minX+r.width*CGFloat(i)/12,y:r.maxY));context.stroke(p,with:.color(cyan.opacity(0.23)),lineWidth:1)
                }
                for i in 0...5 {
                    var p=Path();p.move(to:CGPoint(x:r.minX,y:r.minY+r.height*CGFloat(i)/5));p.addLine(to:CGPoint(x:r.maxX,y:r.minY+r.height*CGFloat(i)/5));context.stroke(p,with:.color(cyan.opacity(0.23)),lineWidth:1)
                }
                context.stroke(Path(r),with:.color(.white),lineWidth:3)
                if game == .goalDuel { symbol("figure.arms.open",point(0.5,0.55),cyan,h*0.42) }
                else { tile(rect(0.13,0.20,0.18,0.23),gold);tile(rect(0.69,0.20,0.18,0.23),gold) }
            }
            for p in [point(0.035,0.06),point(0.965,0.06),point(0.035,0.94),point(0.965,0.94)] {
                context.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-2,width:4,height:4)),with:.color(.white.opacity(0.85)))
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
