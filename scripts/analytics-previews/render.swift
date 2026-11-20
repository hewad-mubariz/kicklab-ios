// macOS-only asset authoring. Run from the repository root:
// swift scripts/analytics-previews/render.swift
// These are illustrative chooser previews, never measured session data.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("design/analytics-previews-20261120/sources")
let assets = root.appendingPathComponent("kicklab/Assets.xcassets/AnalyticsPreviews")
let names = ["foot-rally", "left-right", "beat-gates", "arc-match", "control-surf",
             "peak-zone", "touch-zone", "reach", "footwork", "next-touch", "touch-signature",
             "leg-swing", "ball-flight", "recovery-chain", "control-window", "control-topography",
             "ghost-ball", "zone-game", "height-ladder", "beat-game", "touch-lens"]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255)/255,
        CGFloat((hex >> 8) & 255)/255, CGFloat(hex & 255)/255, alpha])!
}
let mint = color(0x93F2CA), yellow = color(0xFFE16B), cyan = color(0x8DDDF1)
let coral = color(0xF9A48C), muted = color(0x647D81), ink = color(0x0C171B), white = color(0xF4F8F5)
func load(_ name: String) -> CGImage {
    let path = source.appendingPathComponent(name)
    guard let s = CGImageSourceCreateWithURL(path as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(s, 0, nil) else { fatalError("Missing source: \(path.path)") }
    return image
}
let athlete = load("athlete.png"), contact = load("touch-lens.png")

struct Art {
    let c: CGContext
    func line(_ points: [CGPoint], _ color: CGColor, _ width: CGFloat = 1.5, dash: [CGFloat] = []) {
        guard let first = points.first else { return }
        c.saveGState(); c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
        c.setLineDash(phase: 0, lengths: dash); c.beginPath(); c.move(to: first)
        points.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath(); c.restoreGState()
    }
    func curve(_ start: CGPoint, _ a: CGPoint, _ b: CGPoint, _ end: CGPoint, _ color: CGColor, _ width: CGFloat = 2) {
        c.saveGState(); c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round)
        c.beginPath(); c.move(to: start); c.addCurve(to: end, control1: a, control2: b); c.strokePath(); c.restoreGState()
    }
    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ fill: CGColor, ring: CGColor? = nil) {
        let rect = CGRect(x:x-r,y:y-r,width:r*2,height:r*2)
        c.setFillColor(fill); c.fillEllipse(in:rect)
        if let ring { c.setStrokeColor(ring); c.setLineWidth(1.5); c.strokeEllipse(in:rect.insetBy(dx:-4,dy:-4)) }
    }
    func rect(_ r: CGRect, _ fill: CGColor, radius: CGFloat = 5, stroke: CGColor? = nil) {
        let path = CGPath(roundedRect:r,cornerWidth:radius,cornerHeight:radius,transform:nil)
        c.addPath(path); c.setFillColor(fill); c.fillPath()
        if let stroke { c.addPath(path); c.setStrokeColor(stroke); c.setLineWidth(1.3); c.strokePath() }
    }
    func ellipse(_ r: CGRect, _ fill: CGColor, _ stroke: CGColor? = nil) {
        c.setFillColor(fill); c.fillEllipse(in:r)
        if let stroke { c.setStrokeColor(stroke); c.setLineWidth(1.6); c.strokeEllipse(in:r) }
    }
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ fill: CGColor = white) {
        let font = NSFont.systemFont(ofSize:size,weight:.semibold)
        let attr: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor(cgColor:fill)!]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attr))
        c.saveGState(); c.translateBy(x:x,y:y+size); c.scaleBy(x:1,y:-1); c.textPosition = .zero
        CTLineDraw(line,c); c.restoreGState()
    }
    func image(_ im: CGImage, _ r: CGRect, alpha: CGFloat = 1) {
        c.saveGState(); c.setAlpha(alpha); c.interpolationQuality = .high
        c.translateBy(x:r.minX,y:r.maxY); c.scaleBy(x:1,y:-1)
        c.draw(im,in:CGRect(origin:.zero,size:r.size)); c.restoreGState()
    }
    func glow(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ tint: CGColor, alpha: CGFloat = 0.2) {
        let gradient = CGGradient(colorsSpace:space,colors:[tint.copy(alpha:alpha)!,tint.copy(alpha:0)!] as CFArray,locations:[0,1])!
        c.drawRadialGradient(gradient,startCenter:CGPoint(x:x,y:y),startRadius:0,
                             endCenter:CGPoint(x:x,y:y),endRadius:radius,options:[])
    }
    func background(_ accent: CGColor) {
        c.setFillColor(color(0x071216)); c.fill(CGRect(x:0,y:0,width:300,height:180))
        let g = CGGradient(colorsSpace:space,colors:[color(0x17292E),color(0x071216)] as CFArray,locations:[0,1])!
        c.drawLinearGradient(g,start:CGPoint(x:0,y:0),end:CGPoint(x:260,y:180),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        glow(165,85,155,accent,alpha:0.09)
        for x in stride(from:CGFloat(24),through:300,by:28) {
            for y in stride(from:CGFloat(20),through:180,by:28) { dot(x,y,0.6,color(0x8EA9AC,0.19)) }
        }
    }
    func ball(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat = 12, alpha: CGFloat = 1) {
        c.saveGState(); c.setAlpha(alpha); glow(x,y,radius*2,white,alpha:0.12)
        let r = CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2)
        c.saveGState(); c.addEllipse(in:r); c.clip()
        let g = CGGradient(colorsSpace:space,colors:[white,color(0xA7BCBA),color(0x526B70)] as CFArray,locations:[0,0.7,1])!
        c.drawRadialGradient(g,startCenter:CGPoint(x:x-radius*0.4,y:y-radius*0.4),startRadius:0,
                            endCenter:CGPoint(x:x,y:y),endRadius:radius*1.2,options:[.drawsAfterEndLocation])
        let p = CGMutablePath()
        for i in 0..<5 {
            let a = CGFloat(i)*CGFloat.pi*2/5-CGFloat.pi/2
            let point = CGPoint(x:x+cos(a)*radius*0.42,y:y+sin(a)*radius*0.42)
            if i == 0 { p.move(to:point) } else { p.addLine(to:point) }
        }
        p.closeSubpath(); c.addPath(p); c.setFillColor(color(0x314A50)); c.fillPath()
        for i in 0..<5 {
            let a = CGFloat(i)*CGFloat.pi*2/5-CGFloat.pi/2
            line([CGPoint(x:x+cos(a)*radius*0.42,y:y+sin(a)*radius*0.42),CGPoint(x:x+cos(a)*radius,y:y+sin(a)*radius)],color(0x567177,0.7),0.8)
        }
        c.restoreGState(); c.setStrokeColor(color(0xEDF5EE,0.45)); c.setLineWidth(0.8); c.strokeEllipse(in:r); c.restoreGState()
    }
    func person() { image(athlete,CGRect(x:130,y:-38,width:150,height:225),alpha:0.86) }
    func bracket(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat, _ tint: CGColor) {
        line([CGPoint(x:x+5,y:top),CGPoint(x:x,y:top),CGPoint(x:x,y:bottom),CGPoint(x:x+5,y:bottom)],tint,1.5)
        dot(x,(top+bottom)/2,2.5,tint)
    }
    func arrow(_ a: CGPoint, _ b: CGPoint, _ tint: CGColor, width: CGFloat = 2) {
        line([a,b],tint,width)
        let t = atan2(b.y-a.y,b.x-a.x)
        line([CGPoint(x:b.x-8*cos(t-0.55),y:b.y-8*sin(t-0.55)),b,
              CGPoint(x:b.x-8*cos(t+0.55),y:b.y-8*sin(t+0.55))],tint,width)
    }
    func shoe(_ x: CGFloat, _ y: CGFloat, _ tint: CGColor, angle: CGFloat = 0) {
        c.saveGState(); c.translateBy(x:x,y:y); c.rotate(by:angle)
        let p = CGMutablePath(); p.move(to:CGPoint(x:-12,y:23))
        p.addCurve(to:CGPoint(x:-14,y:-22),control1:CGPoint(x:-19,y:9),control2:CGPoint(x:-24,y:-18))
        p.addCurve(to:CGPoint(x:12,y:-22),control1:CGPoint(x:-6,y:-37),control2:CGPoint(x:17,y:-37))
        p.addCurve(to:CGPoint(x:9,y:22),control1:CGPoint(x:20,y:-11),control2:CGPoint(x:3,y:3))
        p.addQuadCurve(to:CGPoint(x:-12,y:23),control:CGPoint(x:10,y:33)); p.closeSubpath()
        c.addPath(p); c.setFillColor(tint.copy(alpha:0.15)!); c.fillPath()
        c.addPath(p); c.setStrokeColor(tint); c.setLineWidth(1.6); c.strokePath()
        for row in 0..<3 { for col in [-1,1] { dot(CGFloat(col)*7,CGFloat(row)*11-19,2.4,tint.copy(alpha:0.7)!) } }
        line([CGPoint(x:-5,y:13),CGPoint(x:5,y:13)],tint,2)
        c.restoreGState()
    }
    func arc(_ x: CGFloat, _ end: CGFloat, _ height: CGFloat, _ tint: CGColor, _ width: CGFloat = 2) {
        curve(CGPoint(x:x,y:139),CGPoint(x:x+(end-x)*0.3,y:139-height),
              CGPoint(x:end-(end-x)*0.3,y:139-height),CGPoint(x:end,y:139),tint,width)
    }
    func draw(_ id: String) {
        background(["foot-rally","left-right","control-surf","footwork"].contains(id) ? mint : yellow)
        switch id {
        case "foot-rally":
            for (y,tint,label) in [(CGFloat(55),mint,"L"),(CGFloat(120),yellow,"R")] {
                rect(CGRect(x:19,y:y-21,width:261,height:42),tint.copy(alpha:0.055)!,radius:12)
                text(label,29,y-11,16,tint)
                line([CGPoint(x:62,y:y),CGPoint(x:268,y:y)],tint.copy(alpha:0.17)!,1,dash:[3,6])
            }
            let ps = [CGPoint(x:73,y:55),CGPoint(x:110,y:120),CGPoint(x:147,y:55),CGPoint(x:184,y:55),CGPoint(x:221,y:120),CGPoint(x:260,y:55)]
            line(ps,mint.copy(alpha:0.55)!,2)
            for (i,p) in ps.enumerated() { dot(p.x,p.y,i == 5 ? 8 : 5,p.y == 55 ? mint : yellow,ring:i == 5 ? mint : nil) }
            text("↔",137,145,15,muted)
        case "left-right":
            glow(94,70,50,mint); glow(206,70,50,yellow)
            shoe(94,69,mint,angle:-0.15); shoe(206,69,yellow,angle:0.15)
            text("L",57,56,17,mint); text("R",239,56,17,yellow)
            rect(CGRect(x:45,y:122,width:210,height:10),color(0x344448))
            rect(CGRect(x:45,y:122,width:126,height:10),mint)
            rect(CGRect(x:175,y:122,width:80,height:10),yellow)
            for i in 0..<10 { dot(51+CGFloat(i)*22,151,3.5,[1,4,6,9].contains(i) ? yellow : mint) }
        case "beat-gates":
            line([CGPoint(x:22,y:90),CGPoint(x:280,y:90)],muted.copy(alpha:0.4)!,1)
            let heights: [CGFloat] = [39,56,43,62,46,31]
            for (i,h) in heights.enumerated() {
                let x = CGFloat(i)*42+43
                rect(CGRect(x:x-11,y:90-h,width:22,height:h*2),mint.copy(alpha:0.07)!,radius:9)
                line([CGPoint(x:x,y:90-h),CGPoint(x:x,y:90+h)],mint.copy(alpha:0.5)!,1.4)
                dot(x,90,5,mint)
            }
            let beats = [CGPoint(x:24,y:90),CGPoint(x:43,y:90),CGPoint(x:66,y:89),CGPoint(x:79,y:47),CGPoint(x:87,y:121),CGPoint(x:98,y:90),CGPoint(x:140,y:90),CGPoint(x:163,y:90),CGPoint(x:176,y:45),CGPoint(x:184,y:119),CGPoint(x:197,y:90),CGPoint(x:279,y:90)]
            line(beats,yellow,2.7); glow(176,45,27,yellow); dot(176,45,4.5,yellow)
        case "arc-match":
            line([CGPoint(x:24,y:140),CGPoint(x:277,y:140)],muted.copy(alpha:0.5)!,1,dash:[4,6])
            arc(28,271,133,color(0x93F2CA,0.22),2); arc(28,271,109,color(0x93F2CA,0.3),2)
            arc(28,271,121,mint,3); arc(28,271,92,yellow,2)
            line([CGPoint(x:148,y:49),CGPoint(x:148,y:70)],yellow,1.2,dash:[2,4])
            ball(149,48,15); dot(28,139,4,mint); dot(271,139,4,mint)
        case "control-surf":
            let p = CGMutablePath(); p.move(to:CGPoint(x:23,y:110)); p.addLine(to:CGPoint(x:277,y:40)); p.addLine(to:CGPoint(x:277,y:108));p.addLine(to:CGPoint(x:23,y:168));p.closeSubpath()
            c.addPath(p);c.setFillColor(mint.copy(alpha:0.07)!);c.fillPath()
            for y in [CGFloat(110),139,168] { line([CGPoint(x:23,y:y),CGPoint(x:277,y:y-67)],mint.copy(alpha:y == 139 ? 0.4 : 0.15)!,1,dash:y == 139 ? [3,6] : []) }
            curve(CGPoint(x:24,y:139),CGPoint(x:100,y:50),CGPoint(x:141,y:170),CGPoint(x:259,y:75),mint,3)
            glow(259,75,27,mint); ball(259,75,12)
        case "peak-zone":
            image(athlete,CGRect(x:182,y:2,width:116,height:174),alpha:0.7)
            rect(CGRect(x:18,y:63,width:260,height:27),yellow.copy(alpha:0.11)!,radius:3)
            for (y,label) in [(CGFloat(29),"CHEST"),(CGFloat(71),"HIP"),(CGFloat(113),"KNEE")] {
                line([CGPoint(x:20,y:y+11),CGPoint(x:279,y:y+11)],muted.copy(alpha:0.3)!,1,dash:[3,5]); text(label,24,y-8,10,y == 71 ? yellow : muted)
            }
            for (i,top) in [CGFloat(84),73,67,89,61,74].enumerated() {
                let x = 39+CGFloat(i)*26
                rect(CGRect(x:x,y:top,width:12,height:151-top),mint.copy(alpha:0.13)!,radius:6)
                line([CGPoint(x:x+6,y:146),CGPoint(x:x+6,y:top)],mint.copy(alpha:0.55)!,2);dot(x+6,top,4.5,yellow)
            }
        case "touch-zone":
            person()
            for (i,pt) in [CGPoint(x:138,y:100),CGPoint(x:149,y:106),CGPoint(x:153,y:114),CGPoint(x:143,y:118),CGPoint(x:160,y:121),CGPoint(x:129,y:116)].enumerated() {
                dot(pt.x,pt.y,i == 2 ? 5 : 3.3,i == 2 ? yellow : mint,ring:i == 2 ? yellow : nil)
            }
            bracket(104,93,131,yellow); line([CGPoint(x:39,y:113),CGPoint(x:99,y:113)],yellow,1)
            for (i,w) in [CGFloat(22),60,36].enumerated() { rect(CGRect(x:30,y:61+CGFloat(i)*15,width:w,height:5),i == 1 ? yellow : mint.copy(alpha:0.35)!,radius:2) }
        case "reach":
            person(); ellipse(CGRect(x:96,y:131,width:143,height:31),mint.copy(alpha:0.09)!,mint.copy(alpha:0.4)!)
            line([CGPoint(x:220,y:147),CGPoint(x:140,y:114)],yellow,2,dash:[4,5])
            dot(220,147,5,mint); dot(140,114,5,yellow,ring:yellow)
            arrow(CGPoint(x:45,y:139),CGPoint(x:118,y:118),yellow)
            bracket(35,99,151,mint)
        case "footwork":
            c.saveGState(); c.translateBy(x:150,y:90);c.rotate(by:-0.12);c.translateBy(x:-150,y:-90)
            rect(CGRect(x:30,y:21,width:240,height:138),mint.copy(alpha:0.04)!,radius:13,stroke:mint.copy(alpha:0.2)!)
            line([CGPoint(x:150,y:23),CGPoint(x:150,y:158)],muted.copy(alpha:0.5)!,1,dash:[3,6])
            let path = [CGPoint(x:92,y:119),CGPoint(x:112,y:87),CGPoint(x:89,y:54),CGPoint(x:129,y:47),CGPoint(x:147,y:76)]
            line(path,mint,2.5); dot(92,119,4,mint);dot(147,76,5,mint,ring:mint)
            shoe(198,92,yellow,angle:0.2);shoe(99,95,mint.copy(alpha:0.35)!,angle:-0.2)
            c.restoreGState()
        case "next-touch":
            person(); glow(100,143,47,yellow)
            ellipse(CGRect(x:61,y:126,width:85,height:27),yellow.copy(alpha:0.1)!,yellow)
            ellipse(CGRect(x:81,y:133,width:45,height:13),.clear,yellow.copy(alpha:0.55)!)
            curve(CGPoint(x:155,y:80),CGPoint(x:107,y:12),CGPoint(x:63,y:83),CGPoint(x:102,y:139),cyan,2.5)
            dot(103,139,4,yellow); line([CGPoint(x:103,y:124),CGPoint(x:103,y:115)],yellow)
            ball(111,59,9,alpha:0.45)
        case "touch-signature":
            for i in 0..<7 {
                let o = CGFloat(i)*6
                curve(CGPoint(x:61+o,y:144),CGPoint(x:4+o,y:6+o),CGPoint(x:294-o,y:16+o),CGPoint(x:204-o,y:144),mint.copy(alpha:0.18+CGFloat(i)*0.07)!,1.6)
            }
            line([CGPoint(x:39,y:144),CGPoint(x:236,y:144)],muted.copy(alpha:0.5)!,1,dash:[3,5])
            bracket(264,44,141,yellow); ball(167,44,15); dot(97,144,4.5,yellow);dot(168,144,4.5,yellow)
        case "leg-swing":
            person()
            let fan = CGMutablePath(); fan.move(to:CGPoint(x:187,y:59));fan.addLine(to:CGPoint(x:95,y:143))
            fan.addQuadCurve(to:CGPoint(x:211,y:158),control:CGPoint(x:153,y:189));fan.closeSubpath()
            c.addPath(fan);c.setFillColor(cyan.copy(alpha:0.12)!);c.fillPath();c.addPath(fan);c.setStrokeColor(cyan.copy(alpha:0.5)!);c.setLineWidth(1);c.strokePath()
            for i in 0..<5 { let x = CGFloat(i)*25+101; line([CGPoint(x:187,y:59),CGPoint(x:x,y:149+sin(CGFloat(i))*10)],cyan.copy(alpha:0.25)!,1) }
            curve(CGPoint(x:99,y:141),CGPoint(x:120,y:164),CGPoint(x:187,y:174),CGPoint(x:211,y:154),yellow,2.5)
            dot(187,59,3.5,cyan);dot(150,117,5,yellow,ring:yellow)
        case "ball-flight":
            arc(37,267,133,cyan.copy(alpha:0.3)!,2);arc(37,267,123,yellow,2.8)
            for (x,y,a) in [(CGFloat(64),CGFloat(90),CGFloat(0.2)),(103,57,0.4),(150,47,1),(200,62,0.4),(242,100,0.2)] { ball(x,y,12,alpha:a) }
            line([CGPoint(x:150,y:69),CGPoint(x:150,y:140)],cyan,1,dash:[3,5])
            line([CGPoint(x:30,y:141),CGPoint(x:275,y:141)],muted.copy(alpha:0.45)!,1)
            dot(37,140,4,yellow);dot(267,140,4,yellow)
        case "recovery-chain":
            let ps = [CGPoint(x:41,y:112),CGPoint(x:100,y:48),CGPoint(x:157,y:125),CGPoint(x:215,y:86),CGPoint(x:267,y:86)]
            for i in 0..<ps.count-1 { arrow(ps[i],ps[i+1],i < 2 ? coral.copy(alpha:0.55)! : mint.copy(alpha:0.7)!,width:2) }
            for (i,p) in ps.enumerated() { glow(p.x,p.y,21,i < 2 ? coral : mint,alpha:0.14);dot(p.x,p.y,i == 4 ? 7 : 5,i < 2 ? coral : mint,ring:i == 4 ? mint : nil) }
            line([CGPoint(x:29,y:86),CGPoint(x:274,y:86)],muted.copy(alpha:0.3)!,1,dash:[3,7])
            ball(100,48,15)
        case "control-window":
            person()
            rect(CGRect(x:95,y:48,width:92,height:92),mint.copy(alpha:0.07)!,radius:12,stroke:mint.copy(alpha:0.65)!)
            for y in [CGFloat(79),109] { line([CGPoint(x:96,y:y),CGPoint(x:185,y:y)],mint.copy(alpha:0.16)!,1) }
            for x in [CGFloat(126),157] { line([CGPoint(x:x,y:49),CGPoint(x:x,y:139)],mint.copy(alpha:0.16)!,1) }
            bracket(76,49,139,yellow);line([CGPoint(x:40,y:89),CGPoint(x:70,y:89)],yellow,1)
            dot(153,79,4,yellow,ring:yellow); dot(110,117,3,mint);dot(126,97,3,mint)
        case "control-topography":
            for i in (0..<7).reversed() {
                let scale = CGFloat(i)*0.13+0.25
                let path = CGMutablePath()
                for j in 0...90 {
                    let t = CGFloat(j)*2*CGFloat.pi/90
                    let r = 1+0.13*sin(t*3)+0.08*cos(t*5)
                    let p = CGPoint(x:147+cos(t)*109*scale*r,y:88+sin(t)*69*scale*r)
                    if j == 0 { path.move(to:p) } else { path.addLine(to:p) }
                }
                path.closeSubpath();c.addPath(path);c.setFillColor(mint.copy(alpha:0.035)!);c.fillPath()
                c.addPath(path);c.setStrokeColor(mint.copy(alpha:0.27+CGFloat(6-i)*0.08)!);c.setLineWidth(1.3);c.strokePath()
            }
            glow(144,83,47,mint,alpha:0.3);dot(145,88,5,yellow,ring:yellow)
            line([CGPoint(x:145,y:48),CGPoint(x:145,y:128)],yellow.copy(alpha:0.4)!,1,dash:[2,6])
            line([CGPoint(x:102,y:88),CGPoint(x:189,y:88)],yellow.copy(alpha:0.4)!,1,dash:[2,6])
        case "ghost-ball":
            person();ball(106,58,18,alpha:0.25);ellipse(CGRect(x:84,y:36,width:44,height:44),.clear,cyan)
            line([CGPoint(x:107,y:82),CGPoint(x:148,y:80)],cyan,1.5,dash:[4,5])
            bracket(67,56,112,yellow);dot(154,79,3,yellow,ring:yellow)
            curve(CGPoint(x:105,y:58),CGPoint(x:59,y:81),CGPoint(x:92,y:119),CGPoint(x:139,y:117),cyan.copy(alpha:0.6)!,1.5)
        case "zone-game":
            person()
            rect(CGRect(x:87,y:30,width:116,height:117),mint.copy(alpha:0.045)!,radius:13)
            let corners: [[CGPoint]] = [[.init(x:87,y:58),.init(x:87,y:30),.init(x:115,y:30)],
                [.init(x:175,y:30),.init(x:203,y:30),.init(x:203,y:58)],
                [.init(x:87,y:119),.init(x:87,y:147),.init(x:115,y:147)],
                [.init(x:175,y:147),.init(x:203,y:147),.init(x:203,y:119)]]
            corners.forEach { line($0,mint,2.5) }
            dot(154,79,3,yellow,ring:yellow)
            for i in 0..<5 { rect(CGRect(x:36,y:39+CGFloat(i)*22,width:19,height:11),i < 4 ? mint : mint.copy(alpha:0.13)!,radius:3) }
        case "height-ladder":
            person()
            for (i,y) in [CGFloat(34),66,98,130].enumerated() {
                line([CGPoint(x:29,y:y),CGPoint(x:125,y:y)],i == 1 ? yellow : mint.copy(alpha:0.3)!,i == 1 ? 2.5 : 1.5)
                dot(29,y,3,i == 1 ? yellow : mint.copy(alpha:0.4)!)
                if i != 1 { ball(112,y-10,7,alpha:0.18) }
            }
            ball(113,55,12);arrow(CGPoint(x:60,y:149),CGPoint(x:60,y:43),yellow,width:1.5)
        case "beat-game":
            person()
            for (r,a) in [(CGFloat(70),CGFloat(0.2)),(53,0.4),(34,0.9)] {
                ellipse(CGRect(x:139-r,y:124-r*0.23,width:r*2,height:r*0.46),yellow.copy(alpha:0.035)!,yellow.copy(alpha:a)!)
            }
            glow(139,124,48,yellow);dot(139,124,5,yellow)
            for i in 0..<5 { rect(CGRect(x:27+CGFloat(i)*17,y:35,width:10,height:CGFloat([15,27,36,23,12][i])),i == 2 ? yellow : mint.copy(alpha:0.5)!,radius:3) }
        case "touch-lens":
            image(contact,CGRect(x:0,y:-10,width:300,height:200))
            c.saveGState()
            let g = CGGradient(colorsSpace:space,colors:[color(0x071216,0),color(0x071216,0.8)] as CFArray,locations:[0,1])!
            c.drawLinearGradient(g,start:CGPoint(x:0,y:102),end:CGPoint(x:0,y:180),options:[]);c.restoreGState()
            let x: CGFloat = 135, y: CGFloat = 107
            dot(x,y,3,yellow,ring:yellow)
            for p in [[CGPoint(x:74,y:93),CGPoint(x:74,y:68),CGPoint(x:99,y:68)],
                      [CGPoint(x:172,y:68),CGPoint(x:197,y:68),CGPoint(x:197,y:93)],
                      [CGPoint(x:74,y:121),CGPoint(x:74,y:144),CGPoint(x:99,y:144)],
                      [CGPoint(x:172,y:144),CGPoint(x:197,y:144),CGPoint(x:197,y:121)]] { line(p,yellow,1.8) }
            line([CGPoint(x:44,y:162),CGPoint(x:256,y:162)],white.copy(alpha:0.4)!,1.5)
            for i in 0..<9 { dot(46+CGFloat(i)*26,162,i == 4 ? 4 : 2,i == 4 ? yellow : white.copy(alpha:0.6)!) }
        default: fatalError("No art for \(id)")
        }
    }
}

extension CGColor { static var clear: CGColor { color(0,0) } }
for name in names {
    // Uniform 5:3 framing at more than 3x the displayed thumbnail size.
    let c = CGContext(data:nil,width:600,height:360,bitsPerComponent:8,bytesPerRow:0,
                      space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x:0,y:360);c.scaleBy(x:2,y:-2)
    Art(c:c).draw(name)
    let file = assets.appendingPathComponent("analytics-preview-\(name).imageset/analytics-preview-\(name).jpg")
    guard let image = c.makeImage(), let destination = CGImageDestinationCreateWithURL(file as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { fatalError("Cannot write \(file.path)") }
    CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.91] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    print("Rendered \(name)")
}
