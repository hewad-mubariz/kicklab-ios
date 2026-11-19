// Copied from the Effects Lab (EffectLab/Graphs/AnalyticsSuiteDrawing.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import CoreGraphics
import CoreText

nonisolated enum AnalyticsSuiteDrawing {
 static func draw(in context:CGContext,rect:CGRect,id:Int,s:AnalyticsSuite.Snapshot,reduceMotion:Bool=false) {
  if id==2 {TimingSpreadDrawing.draw(in:context,rect:rect,s:s.timing,reduceMotion:reduceMotion);return}
  context.saveGState();defer{context.restoreGState()}
  context.translateBy(x:rect.minX,y:rect.minY);context.scaleBy(x:rect.width/342,y:rect.height/212)
  let p=Painter(context),c=context
  p.box(CGRect(x:0,y:0,width:342,height:212),16,p.col(0.025,0.065,0.045,0.94))
  c.addPath(CGPath(roundedRect:CGRect(x:0.4,y:0.4,width:341.2,height:211.2),cornerWidth:16,cornerHeight:16,transform:nil));c.setStrokeColor(p.col(0.68,0.91,0.76,0.25));c.setLineWidth(0.65);c.strokePath()
  p.text(AnalyticsSuite.names[id].uppercased(),16,12,11,p.white,"Bold")
  let titles=["Completed apexes · thirds of body height","Flight duration · estimated contact foot","","Tracked time · relative to body","Initial direction · 2D image plane","Projected speed · ball diameters / s","Return to center · ±0.25 body widths","Contact order · pose estimates","First 8 vs latest 8 intervals","Current values vs comparable past sessions"]
  p.text(titles[id],16,30,8,p.muted)
  func fmt(_ x:Double?,_ f:String="%.2f")->String{x.map{String(format:f,$0)} ?? "—"}
  let flights=s.flights
  switch id {
  case 0:
   p.text("\(flights.count) FLIGHTS",326,13,8,p.muted,"Medium",1)
   for (i,f) in flights.suffix(16).enumerated() {let x=CGFloat(45+i*16),y=CGFloat(70-f.apex*15);p.dot(x,y,2.2,p.mint);if i>0{let prev=Array(flights.suffix(16))[i-1];p.line(x-16,CGFloat(70-prev.apex*15),x,y,p.faint)}}
   let counts=[flights.filter{$0.apex>=2.0/3}.count,flights.filter{$0.apex>=1.0/3 && $0.apex<2.0/3}.count,flights.filter{$0.apex<1.0/3}.count]
   for i in 0..<3 {let y=CGFloat(86+i*23),value=flights.isEmpty ? 0:Double(counts[i])/Double(flights.count)
    p.text(["UPPER","MIDDLE","LOWER"][i],16,y,8,p.muted);p.box(CGRect(x:78,y:y+1,width:199,height:11),5,p.faint);if value>0{p.box(CGRect(x:78,y:y+1,width:199*value,height:11),5,p.lime)};p.text(flights.isEmpty ? "—":String(format:"%.0f%%",value*100),326,y-1,10,p.white,"Bold",1)
   }
   let cv=AnalyticsSuite.cv(flights.map(\.rise))
   p.stats([("VALID FLIGHTS",String(flights.count)),("RISE VARIATION",fmt(cv,"%.0f")+(cv==nil ? "":"%"))])
  case 1:
   let left=flights.filter{$0.side=="L"}.map(\.duration),right=flights.filter{$0.side=="R"}.map(\.duration)
   p.text("\(flights.filter{$0.side=="U"}.count) UNKNOWN",326,13,8,p.muted,"Medium",1)
   func x(_ value:Double)->CGFloat {70+CGFloat(min(0.9,max(0.3,value))-0.3)/0.6*240}
   for (i,values) in [left,right].enumerated(){let y=CGFloat(78+i*45),color=i==0 ? p.mint:p.gold
    p.text(i==0 ? "LEFT":"RIGHT",16,y-12,9,color,"Bold");p.text("n = \(values.count)",16,y+2,7,p.muted)
    p.line(70,y,310,y,p.faint)
    if let a=AnalyticsSuite.q(values,0.25),let b=AnalyticsSuite.q(values,0.75){p.box(CGRect(x:x(a),y:y-6,width:max(2,x(b)-x(a)),height:12),3,p.alpha(color,0.25))}
    for (j,v) in values.enumerated(){p.dot(x(v),y+CGFloat((j%3)-1)*3,2,color)}
    if let median=AnalyticsSuite.q(values,0.5){p.line(x(median),y-10,x(median),y+10,p.white,1.3)}
    let outside=values.filter{$0<0.3 || $0>0.9}.count;if outside>0{p.text("\(outside) beyond scale",310,y+12,6,p.muted,"Medium",1)}
   }
   for v in [0.3,0.5,0.7,0.9]{p.text(String(format:"%.1f",v),x(v),145,7,p.muted,"Medium",0.5)}
   p.stats([("LEFT MEDIAN",fmt(AnalyticsSuite.q(left,0.5))+" s"),("RIGHT MEDIAN",fmt(AnalyticsSuite.q(right,0.5))+" s")])
  case 3:
   let area=CGRect(x:46,y:53,width:250,height:99);p.box(area,5,p.col(0.03,0.11,0.065));let peak=s.heat.max() ?? 0
   c.saveGState();c.clip(to:area)
   for i in s.heat.indices where s.heat[i]>0 {let alpha=peak>0 ? s.heat[i]/peak:0,x=area.minX+(CGFloat(i%18)+0.5)/18*area.width,y=area.minY+(CGFloat(i/18)+0.5)/10*area.height
    let col=p.col(0.23+0.4*CGFloat(alpha),0.9,0.3,CGFloat(alpha)*0.65)
    let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[col,p.alpha(col,0)] as CFArray,locations:[0,1])!
    c.drawRadialGradient(gradient,startCenter:CGPoint(x:x,y:y),startRadius:0,endCenter:CGPoint(x:x,y:y),endRadius:19,options:[])
   }
   let mid=area.midX;p.line(mid-area.width/8,53,mid-area.width/8,152,p.alpha(p.white,0.3),0.6);p.line(mid+area.width/8,53,mid+area.width/8,152,p.alpha(p.white,0.3),0.6)
   let path=s.heatPath.map{AnalyticsSuite.Point(x:Double(area.minX)+($0.x+1)/2*Double(area.width),y:Double(area.maxY)-$0.y*Double(area.height))}
   p.path(path,p.white,1.2);if let a=path.last{p.dot(CGFloat(a.x),CGFloat(a.y),2.5,p.white)};c.restoreGState()
   p.text("TOP",16,55,7,p.muted);p.text("BASE",13,141,7,p.muted);p.text("LEFT",46,155,6,p.muted);p.text("CENTER",171,155,6,p.muted,"Medium",0.5);p.text("RIGHT",296,155,6,p.muted,"Medium",1)
   p.text(String(format:"%.1f s VALID",s.heatValidSeconds),326,13,8,p.muted,"Medium",1)
   p.stats([("IN CENTER",fmt(s.centerPercent,"%.0f")+"%"),("SIDE SPREAD",fmt(s.sideSpread)+" widths")])
  case 4:
   p.text("\(s.launches.count) LAUNCHES",326,13,8,p.muted,"Medium",1)
   let origin=CGPoint(x:171,y:145)
   func point(_ a:Double,_ r:CGFloat=78)->CGPoint {let d=min(75,max(-75,a))*Double.pi/180;return CGPoint(x:171+sin(d)*r,y:145-cos(d)*r)}
   for a in [-60.0,-30,0,30,60] {let q=point(a);p.line(origin.x,origin.y,q.x,q.y,p.faint,0.65);let t=point(a,91);p.text(String(format:"%+.0f°",a),t.x,t.y-3,7,p.muted,"Medium",0.5)}
   for a in s.launches {let q=point(a.angle);p.line(origin.x,origin.y,q.x,q.y,p.alpha(p.mint,0.35),1.1)}
   if s.launches.count>=5,let lo=AnalyticsSuite.q(s.launches.map(\.angle),0.1),let hi=AnalyticsSuite.q(s.launches.map(\.angle),0.9){let points=(0...30).map{i -> AnalyticsSuite.Point in let q=point(lo+(hi-lo)*Double(i)/30,68);return .init(x:q.x,y:q.y)};p.path(points,p.gold,2.4)}
   if let last=s.launches.last {let q=point(last.angle);p.line(origin.x,origin.y,q.x,q.y,p.white,2);p.dot(q.x,q.y,2.3,p.white)}
   p.dot(origin.x,origin.y,3,p.white)
   let a=AnalyticsSuite.q(s.launches.map(\.angle),0.1),b=AnalyticsSuite.q(s.launches.map(\.angle),0.9)
   p.stats([("MEDIAN BIAS",fmt(AnalyticsSuite.q(s.launches.map(\.angle),0.5),"%+.0f")+"°"),("MIDDLE 80%",s.launches.count>=5 ? fmt(a,"%+.0f")+" to "+fmt(b,"%+.0f")+"°":"Need 5 launches")])
  case 5:
   let area=CGRect(x:36,y:60,width:282,height:90),start=max(0,s.time-6),end=max(6,s.time),limit=max(20,ceil((s.recentPeak ?? 0)/10)*10)
   p.grid(area,topLabel:String(format:"%.0f",limit),bottomLabel:"0")
   let points=s.speed.map{AnalyticsSuite.Point(x:36+($0.x-start)/(end-start)*282,y:150-$0.y/limit*90)}
   p.timedPath(s.speed,points,p.lime,1.8)
   for e in s.sequence where e.time>=start {let x=36+(e.time-start)/(end-start)*282;p.line(x,145,x,151,p.alpha(p.gold,0.6))}
   if let a=points.last,s.currentSpeed != nil{p.dot(a.x,a.y,2.7,p.white)}
   p.text(String(format:"%.0f s",start),36,153,7,p.muted);p.text(String(format:"%.0f s",end),318,153,7,p.muted,"Medium",1)
   p.stats([("CURRENT",fmt(s.currentSpeed,"%.1f")+" diam/s"),("PEAK · LAST 6 s",fmt(s.recentPeak,"%.1f")+" diam/s")])
  case 6:
   let area=CGRect(x:36,y:57,width:282,height:86),start=max(0,s.time-6),end=max(6,s.time),extent=max(1,ceil(s.recoveryPath.map{abs($0.y)}.max() ?? 1))
   p.box(CGRect(x:36,y:100-0.25/extent*43,width:282,height:0.5/extent*43),3,p.alpha(p.mint,0.12));p.grid(area,topLabel:String(format:"+%.0f",extent),bottomLabel:String(format:"−%.0f",extent))
   p.line(36,100,318,100,p.alpha(p.white,0.18),0.6)
   let points=s.recoveryPath.map{AnalyticsSuite.Point(x:36+($0.x-start)/(end-start)*282,y:100-$0.y/extent*43)}
   p.timedPath(s.recoveryPath,points,p.mint,1.6)
   for e in s.episodes where e.end>=start {let a=36+(max(start,e.start)-start)/(end-start)*282,b=36+(e.end-start)/(end-start)*282;p.line(a,151,b,151,p.gold,1.6);p.line(b,147,b,154,p.gold)}
   if let t=s.ongoingStart {let a=36+(max(start,t)-start)/(end-start)*282;p.line(a,151,318,151,p.muted,1.2)}
   let label=s.ongoingStart != nil ? "CURRENT EXCURSION":"LAST RETURN"
   let value=s.ongoingStart.map{s.time-$0} ?? s.episodes.last.map{$0.end-$0.start}
   p.text("\(s.episodes.count) RETURNS",326,13,8,p.muted,"Medium",1)
   let touches=s.ongoingStart != nil ? s.ongoingContacts:s.episodes.last?.contacts
   p.stats([(label,fmt(value)+" s"),(s.ongoingStart == nil ? "TOUCHES TO RETURN":"TOUCHES SO FAR",touches.map{String($0)} ?? "—")])
  case 7:
   p.text("\(s.unknownContacts) UNKNOWN",326,13,8,p.muted,"Medium",1)
   p.text("L",17,73,9,p.mint,"Bold");p.text("?",17,98,8,p.muted);p.text("R",17,123,9,p.gold,"Bold")
   for y:CGFloat in [80,105,130] {p.line(34,y,319,y,p.faint,0.5)}
   func pos(_ i:Int)->CGPoint {let e=s.sequence[i];return CGPoint(x:43+CGFloat(i)*24,y:e.side=="L" ? 80:e.side=="R" ? 130:105)}
   for i in s.sequence.indices {let e=s.sequence[i],q=pos(i),color=e.side=="L" ? p.mint:e.side=="R" ? p.gold:p.muted
    if i>0,e.side != "U",s.sequence[i-1].side != "U" {let last=pos(i-1);p.line(last.x,last.y,q.x,q.y,p.alpha(p.white,0.24),1)}
    p.dot(q.x,q.y,5,color);p.text(e.side=="U" ? "?":e.side,q.x,q.y-4,6,p.col(0.02,0.1,0.05),"Bold",0.5)
   }
   p.text("EARLIER",36,149,7,p.muted);p.text("LATEST",318,149,7,p.muted,"Medium",1)
   p.stats([("KNOWN-PAIR SWITCHES","\(s.switches) / \(s.pairs)"),("LONGEST SAME FOOT","\(s.longestRun) touches")])
  case 8:
   let start=s.trend.first?.time ?? 0,end=max(start+1,s.time),maxJ=max(100,ceil((s.trend.map(\.jitter).max() ?? 0)/100)*100)
   p.text("TIMING IQR",16,56,7,p.muted);p.text("ms",16,68,7,p.muted)
   p.text("SIDE SPREAD",16,111,7,p.muted);p.text("body widths",16,123,6,p.muted)
   let a=s.trend.map{AnalyticsSuite.Point(x:80+($0.time-start)/(end-start)*238,y:96-$0.jitter/maxJ*40)}
   let b=s.trend.compactMap{r -> AnalyticsSuite.Point? in r.spread.map{.init(x:80+(r.time-start)/(end-start)*238,y:148-min(2,$0)/2*40)}}
   p.line(80,96,318,96,p.faint);p.line(80,148,318,148,p.faint);p.path(a,p.mint,1.7);p.path(b,p.gold,1.7)
   p.text(String(format:"%.0f",maxJ),80,47,6,p.muted);p.text("2.0",80,100,6,p.muted)
   if s.trend.isEmpty{p.text("Collecting 8 intervals",200,83,9,p.muted,"Medium",0.5)}
   let dj=s.latestTrend.flatMap{last in s.earlyTrend.map{last.jitter-$0.jitter}},ds=s.latestTrend?.spread.flatMap{last in s.earlyTrend?.spread.map{last-$0}}
   p.stats([("TIMING CHANGE",dj==nil ? "Need 16 intervals":fmt(dj,"%+.0f")+" ms"),("SIDE CHANGE",ds==nil ? "—":fmt(ds,"%+.2f")+" widths")])
  case 9:
   p.text("\(s.baselineCount) / 5 PAST",326,13,8,p.muted,"Medium",1)
   let names=["TIMING JITTER","RISE VARIATION","SIDE SPREAD"],units=["ms","%","widths"],limits=[200.0,100,1.5]
   for i in 0..<3 {let y=CGFloat(67+i*33),limit=limits[i]
    p.text(names[i],16,y-3,7.5,p.muted);p.line(133,y+2,261,y+2,p.alpha(p.white,0.18),2)
    p.text("0",133,y+10,6,p.muted);p.text(String(format:"%g",limit),261,y+10,6,p.muted,"Medium",1)
    if let a=s.currentMetrics[i] {let x=133+min(limit,max(0,a))/limit*128;p.dot(x,y+2,3,p.lime)}
    if let b=s.baselineMetrics[i] {let x=133+min(limit,max(0,b))/limit*128;p.dot(x,y+2,3,p.white)}
    p.text(fmt(s.currentMetrics[i],i==2 ? "%.2f":"%.0f")+" "+units[i],326,y-4,9,p.white,"Bold",1)
   }
   p.text(s.baselineCount<5 ? "Current only · no comparable baseline yet":"Lime: current   White: past-session median",16,151,7,p.muted)
   p.stats([("CURRENT WINDOW","\(s.timing.count) intervals"),("BASELINE",s.baselineCount<5 ? "Need 5 sessions":"\(s.baselineCount) sessions")])
  default:break
  }
 }
 final class Painter {
  let c:CGContext;init(_ c:CGContext){self.c=c}
  func col(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1)->CGColor{CGColor(red:r,green:g,blue:b,alpha:a)}
  var white:CGColor{col(0.97,0.99,0.97)};var muted:CGColor{col(0.65,0.75,0.69)};var lime:CGColor{col(0.69,1,0.27)};var mint:CGColor{col(0.38,0.96,0.68)};var gold:CGColor{col(1,0.82,0.24)};var faint:CGColor{col(0.8,0.95,0.86,0.12)}
  func alpha(_ color:CGColor,_ a:CGFloat)->CGColor{color.copy(alpha:a)!}
  func text(_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:CGColor?=nil,_ weight:String="Medium",_ align:CGFloat=0){
   let font=CTFontCreateWithName("HelveticaNeue-\(weight)" as CFString,size,nil),line=CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color ?? white]))
   let width=CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil));c.saveGState();c.translateBy(x:x-width*align,y:y+size);c.scaleBy(x:1,y:-1);c.textPosition = .zero;CTLineDraw(line,c);c.restoreGState()
  }
  func line(_ x:CGFloat,_ y:CGFloat,_ xx:CGFloat,_ yy:CGFloat,_ color:CGColor,_ width:CGFloat=1){c.setStrokeColor(color);c.setLineWidth(width);c.move(to:CGPoint(x:x,y:y));c.addLine(to:CGPoint(x:xx,y:yy));c.strokePath()}
  func dot(_ x:CGFloat,_ y:CGFloat,_ r:CGFloat,_ color:CGColor){c.setFillColor(color);c.fillEllipse(in:CGRect(x:x-r,y:y-r,width:r*2,height:r*2))}
  func box(_ r:CGRect,_ radius:CGFloat,_ color:CGColor){c.addPath(CGPath(roundedRect:r,cornerWidth:radius,cornerHeight:radius,transform:nil));c.setFillColor(color);c.fillPath()}
  func path(_ points:[AnalyticsSuite.Point],_ color:CGColor,_ width:CGFloat=1){guard let first=points.first else{return};c.setStrokeColor(color);c.setLineWidth(width);c.setLineJoin(.round);c.setLineCap(.round);c.move(to:CGPoint(x:first.x,y:first.y));for p in points.dropFirst(){c.addLine(to:CGPoint(x:p.x,y:p.y))};c.strokePath()}
  func timedPath(_ times:[AnalyticsSuite.Point],_ pixels:[AnalyticsSuite.Point],_ color:CGColor,_ width:CGFloat){var segment=[AnalyticsSuite.Point]();for i in pixels.indices{if i>0 && times[i].x-times[i-1].x>0.101{path(segment,color,width);segment=[]};segment.append(pixels[i])};path(segment,color,width)}
  func grid(_ area:CGRect,topLabel:String,bottomLabel:String){for y in [area.minY,area.midY,area.maxY]{line(area.minX,y,area.maxX,y,faint,0.5)};text(topLabel,area.minX-5,area.minY-4,7,muted,"Medium",1);text(bottomLabel,area.minX-5,area.maxY-4,7,muted,"Medium",1)}
  func stats(_ items:[(String,String)]) {line(16,165,326,165,col(0.75,0.9,0.8,0.22),0.5);for (i,item) in items.enumerated(){let x:CGFloat=i==0 ? 16:326,alignment:CGFloat=i==0 ? 0:1;text(item.0,x,175,7.5,muted,"Medium",alignment);text(item.1,x,187,item.1.count>17 ? 10:14,i==0 ? white:gold,"Bold",alignment)}}
 }
}
