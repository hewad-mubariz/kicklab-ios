// Copied from the Effects Lab (EffectLab/Graphs/TimingSpreadDrawing.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics
import CoreText

/// Shared Core Graphics HUD renderer, usable by a Mac export or an iOS view.
/// All coordinates below are top-left in a 342 x 212 point card.
nonisolated enum TimingSpreadDrawing {
    static let size = CGSize(width:342,height:212)
    static func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1)->CGColor {
        CGColor(red:r,green:g,blue:b,alpha:a)
    }
    static let white=color(0.97,0.99,0.97), muted=color(0.65,0.75,0.69)
    static let lime=color(0.69,1,0.27), mint=color(0.38,0.96,0.68), gold=color(1,0.82,0.24)
    static func draw(in c:CGContext,rect:CGRect,s:TimingSpread.Snapshot,reduceMotion:Bool=false) {
        c.saveGState();defer {c.restoreGState()}
        c.translateBy(x:rect.minX,y:rect.minY);c.scaleBy(x:rect.width/size.width,y:rect.height/size.height)
        c.setAllowsAntialiasing(true)
        let outer=CGRect(origin:.zero,size:size),rounded=CGPath(roundedRect:outer,cornerWidth:16,cornerHeight:16,transform:nil)
        c.addPath(rounded);c.setFillColor(color(0.025,0.065,0.045,0.94));c.fillPath()
        c.addPath(rounded);c.setStrokeColor(color(0.68,0.91,0.76,0.25));c.setLineWidth(0.65);c.strokePath()
        func text(_ string:String,_ x:CGFloat,_ y:CGFloat,_ fontSize:CGFloat,_ col:CGColor=white,_ weight:String="Medium",_ alignment:CGFloat=0) {
            let font=CTFontCreateWithName("HelveticaNeue-\(weight)" as CFString,fontSize,nil)
            let attrs:[NSAttributedString.Key:Any] = [.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):col]
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:attrs))
            let width=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
            c.saveGState();c.translateBy(x:x-width*alignment,y:y+fontSize);c.scaleBy(x:1,y:-1)
            c.textPosition = .zero;CTLineDraw(line,c);c.restoreGState()
        }
        func line(_ x:CGFloat,_ y:CGFloat,_ xx:CGFloat,_ yy:CGFloat,_ col:CGColor,_ width:CGFloat=1) {
            c.setStrokeColor(col);c.setLineWidth(width);c.move(to:CGPoint(x:x,y:y));c.addLine(to:CGPoint(x:xx,y:yy));c.strokePath()
        }
        func dot(_ x:CGFloat,_ y:CGFloat,_ radius:CGFloat,_ col:CGColor) {
            c.setFillColor(col);c.fillEllipse(in:CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2))
        }
        text("TIMING SPREAD",16,12,11,white,"Bold")
        text("\(s.count) / 20 INTERVALS",326,13,8,muted,"Medium",1)
        text(s.awaitingTouchAfterPause ? "Pause · waiting for a new run" : "Last completed intervals · seconds",16,29,8,muted)

        let left:CGFloat=36,right:CGFloat=306,top:CGFloat=77,bottom:CGFloat=143
        let binW=(right-left)/12
        func x(_ seconds:Double)->CGFloat { left+CGFloat(min(0.90,max(0.30,seconds))-0.30)/0.60*(right-left) }
        var ymax=4
        while ymax < (s.bins.max() ?? 0) { ymax *= 2 }
        // Count axis uses explicit 4/8/16/32 steps. The time axis never shifts.
        for n in 0...2 {
            let y=bottom-CGFloat(n)/2*(bottom-top)
            line(left,y,right,y,color(0.80,0.95,0.86,n==0 ? 0.32:0.10),0.5)
            text(String(ymax*n/2),29,y-5,7,muted,"Medium",1)
        }
        for value in [0.30,0.45,0.60,0.75,0.90] {
            line(x(value),bottom,x(value),bottom+3,color(0.68,0.80,0.73),0.6)
            text(String(format:"%0.2f",value),x(value),bottom+5,7,muted,"Medium",0.5)
        }
        if s.distributionReady {
            let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(0.12,0.43,0.19),lime,mint] as CFArray,locations:[0,0.7,1])!
            for i in 1...12 where s.bins[i]>0 {
                let h=CGFloat(s.bins[i])/CGFloat(ymax)*(bottom-top)
                let r=CGRect(x:left+CGFloat(i-1)*binW+1.5,y:bottom-h,width:binW-3,height:h)
                c.saveGState();c.addPath(CGPath(roundedRect:r,cornerWidth:2.4,cornerHeight:2.4,transform:nil));c.clip()
                c.drawLinearGradient(gradient,start:CGPoint(x:0,y:bottom),end:CGPoint(x:0,y:top),options:[]);c.restoreGState()
            }
        } else {
            // Show real observations for the first few touches, not an invented density curve.
            var stack=[Int:Int]()
            for interval in s.intervals {
                let bucket=TimingSpread.bin(for:interval.seconds),level=stack[bucket,default:0]
                stack[bucket]=level+1
                dot(x(interval.seconds),bottom-5-CGFloat(level)*7,2.5,mint)
            }
            text(s.count==0 ? "Waiting for two touches" : "Collecting \(s.count) / 5 intervals",171,55,9,muted,"Medium",0.5)
        }
        // Overflow observations stay in the summaries and have visible counters.
        if s.bins[0]>0 { text("‹\(s.bins[0])",17,130,8,gold); }
        if s.bins[13]>0 { text("\(s.bins[13])›",326,130,8,gold,"Medium",1); }
        if let median=s.median {
            line(x(median),top-3,x(median),bottom,white,1.25)
            dot(x(median),top-3,2,white)
        }
        if let a=s.q10,let b=s.q90 {
            line(x(a),65,x(b),65,gold,1.8)
            line(x(a),61,x(a),69,gold,1.8);line(x(b),61,x(b),69,gold,1.8)
            text("MIDDLE 80%",171,47,8.5,gold,"Bold",0.5)
        }
        if s.distributionReady,let newest=s.intervals.last {
            let i=TimingSpread.bin(for:newest.seconds),xx=x(newest.seconds)
            let yy=bottom-CGFloat(s.bins[i])/CGFloat(ymax)*(bottom-top)-5
            let age=max(0,s.time-newest.end),pulse=reduceMotion ? 0:max(0,1-age/0.25)
            if pulse>0 {dot(xx,yy,3+CGFloat(pulse)*4,color(1,1,1,CGFloat(pulse)*0.24))}
            dot(xx,yy,2.5,white)
        }
        line(16,165,326,165,color(0.75,0.9,0.8,0.22),0.5)
        text("MEDIAN",16,175,7.5,muted)
        text(s.median.map{String(format:"%0.2f s",$0)} ?? "—",16,186,16,white,"Bold")
        text("MIDDLE 80%",122,175,7.5,muted)
        let range=(s.q10 != nil && s.q90 != nil) ? String(format:"%0.2f–%0.2f s",s.q10!,s.q90!):"Need 5 intervals"
        text(range,122,188,s.q10==nil ? 9:12.5,s.q10==nil ? muted:gold,"Medium")
        text("LATEST",326,175,7.5,muted,"Medium",1)
        text(s.latest.map{String(format:"%0.2f s",$0)} ?? "—",326,186,16,white,"Bold",1)
    }
}
