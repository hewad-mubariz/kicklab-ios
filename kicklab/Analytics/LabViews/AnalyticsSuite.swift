// Copied from the Effects Lab (EffectLab/Graphs/AnalyticsSuite.swift), 2026-11-19; only isolation is added for the app.
import Foundation

nonisolated enum AnalyticsSuite {
 struct Sample:Codable,Equatable {
  let time,x,y,radius:Double;let valid:Bool
  let personX,personY,personWidth,personHeight:Double
  var bodyValid:Bool {valid && personWidth>40 && personHeight>100}
  var u:Double {(x-personX)/max(1,personWidth)}
  var v:Double {(personY+personHeight/2-y)/max(1,personHeight)}
 }
 struct Event:Codable,Equatable {let time,availableAt:Double;var side:String}
 struct History:Codable,Equatable {let id,contextKey,definitionsVersion:String;let jitter,riseVariation,sideSpread:Double;let sampleCount:Int}
 struct Input:Codable {let samples:[Sample],events:[Event],history:[History];let contextKey,definitionsVersion:String}
 struct Point:Codable,Equatable {let x,y:Double}
 struct Flight:Codable,Equatable {let start,end,duration,apex,rise:Double;let side:String}
 struct Launch:Codable,Equatable {let time,angle:Double}
 struct Episode:Codable,Equatable {let start,end:Double;let contacts:Int}
 struct Trend:Codable,Equatable {let time,jitter:Double;let spread:Double?}
 struct Snapshot:Codable,Equatable {
  let time:Double,timing:TimingSpread.Snapshot
  let flights:[Flight],launches:[Launch]
  let heat:[Double],heatPath:[Point],heatValidSeconds:Double,heatOutsideSeconds:Double,centerPercent:Double?,sideSpread:Double?
  let speed:[Point],currentSpeed:Double?,recentPeak:Double?
  let recoveryPath:[Point],episodes:[Episode],ongoingStart:Double?,ongoingContacts:Int,censoredEpisodes:Int
  let sequence:[Event],switches:Int,pairs:Int,longestRun:Int,unknownContacts:Int
  let trend:[Trend],earlyTrend:Trend?,latestTrend:Trend?
  let currentMetrics:[Double?],baselineMetrics:[Double?],baselineCount:Int
 }
 static let names=["Height Mix","Foot Comparison","Timing Spread","Control Heatmap","Launch Bias","Speed Profile","Recovery Analysis","Touch Patterns","Session Trend","Personal Baseline"]
 static let slugs=["height-mix","foot-comparison","timing-spread","control-heatmap","launch-bias","speed-profile","recovery-analysis","touch-patterns","session-trend","personal-baseline"]
 static func q(_ values:[Double],_ p:Double)->Double? {TimingSpread.quantile(values.filter(\.isFinite).sorted(),p)}
 static func weightedQ(_ values:[(Double,Double)],_ p:Double)->Double? {
  let a=values.filter{$0.0.isFinite && $0.1>0}.sorted{$0.0<$1.0},total=a.reduce(0){$0+$1.1};guard total>0 else{return nil}
  var seen=0.0;for x in a {seen+=x.1;if seen>=total*p{return x.0}};return a.last?.0
 }
 static func cv(_ a:[Double])->Double? {guard a.count>=5 else{return nil};let mean=a.reduce(0,+)/Double(a.count);guard mean>0.00001 else{return nil};return sqrt(a.reduce(0){$0+pow($1-mean,2)}/Double(a.count))/mean*100}
 static func slope(_ a:[Sample],_ value:(Sample)->Double)->Double? {
  guard a.count>=3 else{return nil}
  var slopes=[Double]()
  for i in a.indices {for j in (i+1)..<a.count where a[j].time-a[i].time>0.01 {slopes.append((value(a[j])-value(a[i]))/(a[j].time-a[i].time))}}
  return q(slopes,0.5)
 }
 struct Timeline {
  let input:Input
  init(_ input:Input){self.input=input}
  func snapshot(at request:Double)->Snapshot {
   let now=request.isFinite ? max(0,request):0
   let all=input.samples.filter{$0.time<=now}.sorted{$0.time<$1.time}
   let events=input.events.filter{$0.time<=now}.sorted{$0.time<$1.time}.map{e -> Event in var x=e;if e.availableAt>now{x.side="U"};return x}
   let timing=TimingSpread.Timeline(touches:events.map(\.time)).snapshot(at:now)
   let runStart=zip(events,events.dropFirst()).filter{$1.time-$0.time>2}.last?.1.time ?? events.first?.time ?? 0
   let runEvents=events.filter{$0.time>=runStart}
   let run=all.filter{$0.time>=runStart}
   func contiguous(_ a:[Sample],body:Bool=false)->Bool {
    a.count>=3 && a.allSatisfy{body ? $0.bodyValid:$0.valid} && zip(a,a.dropFirst()).allSatisfy{$1.time-$0.time<=0.101}
   }
   var flights=[Flight]()
   for (a,b) in zip(runEvents,runEvents.dropFirst()) where b.time-a.time<=2 {
    let points=run.filter{$0.time>=a.time && $0.time<=b.time}
    guard contiguous(points,body:true),let low=points.min(by:{$0.y<$1.y}),let first=points.first,low.time>first.time,low.time<points.last!.time else{continue}
    let body=q(points.map(\.personHeight),0.5)!
    flights.append(Flight(start:a.time,end:b.time,duration:b.time-a.time,apex:low.v,rise:max(0,(first.y-low.y)/body),side:a.side))
   }
   flights=Array(flights.suffix(20))
   if timing.awaitingTouchAfterPause {flights=[]}
   var launches=[Launch]()
   for e in runEvents where now>=e.time+0.17 {
    let points=run.filter{$0.time>e.time+0.015 && $0.time<=e.time+0.17}
    guard contiguous(points),let vx=slope(points,{$0.x}),let vy=slope(points,{$0.y}),vy < -10 else{continue}
    launches.append(Launch(time:e.time+0.17,angle:atan2(vx,-vy)*180/Double.pi))
   }
   launches=Array(launches.suffix(20))
   let recent=all.filter{$0.time>=max(runStart,now-6)}
   var heat=[Double](repeating:0,count:18*10),weighted=[(Double,Double)](),validSeconds=0.0,insideSeconds=0.0,outside=0.0
   for (a,b) in zip(recent,recent.dropFirst()) where a.bodyValid && b.bodyValid && b.time-a.time<=0.101 {
    let dt=b.time-a.time,u=b.u,v=b.v;validSeconds+=dt;weighted.append((u,dt))
    if abs(u)<=0.25 {insideSeconds+=dt}
    if u>=(-1) && u<=1 && v>=0 && v<=1 {
     let x=min(17,max(0,Int((u+1)/2*18))),y=min(9,max(0,Int((1-v)*10)));heat[y*18+x]+=dt
    } else{outside+=dt}
   }
   var path=[Point]();var lastTime:Double?
   for b in recent where b.time>=now-1.25 {
    if !b.bodyValid || (lastTime.map{b.time-$0>0.101} ?? false) {path.removeAll()}
    if b.bodyValid {path.append(Point(x:b.u,y:b.v));lastTime=b.time}else{lastTime=nil}
   }
   var speeds=[Point]()
   for i in all.indices where all[i].time>=now-6 {
    let points=Array(all[max(0,i-5)...i]);guard contiguous(points),let vx=slope(points,{$0.x}),let vy=slope(points,{$0.y}) else{continue}
    let diameter=2*(q(points.map(\.radius),0.5) ?? 0)
    if diameter>0 {speeds.append(Point(x:all[i].time,y:hypot(vx,vy)/diameter))}
   }
   let currentSpeed=speeds.last.flatMap{now-$0.x<=0.1 ? $0.y:nil}
   var episodes=[Episode](),active:Double?,outCandidate:Double?,inCandidate:Double?,previous:Double?,censored=0
   for b in run {
    if !b.bodyValid || (previous.map{b.time-$0>0.101} ?? false) {
     if active != nil {censored+=1};active=nil;outCandidate=nil;inCandidate=nil;previous=b.time;continue
    }
    previous=b.time
    if abs(b.u)>0.25 {
     inCandidate=nil
     if active==nil {if outCandidate==nil{outCandidate=b.time};if b.time-outCandidate!>=0.12 {active=outCandidate}}
    } else {
     outCandidate=nil
     if let start=active {
      if inCandidate==nil{inCandidate=b.time}
      if b.time-inCandidate!>=0.12 {
       let end=b.time // only count a return once re-entry is confirmed
       episodes.append(Episode(start:start,end:end,contacts:events.filter{$0.time>start && $0.time<=end}.count))
       active=nil;inCandidate=nil
      }
     }
    }
   }
   // A missing tail never completes or extends a measured recovery episode.
   if let last=run.last,now-last.time>0.101 || timing.awaitingTouchAfterPause {if active != nil{censored+=1};active=nil}
   let recovery=recent.filter(\.bodyValid).map{Point(x:$0.time,y:$0.u)}
   var pairs=0,switches=0,longest=0,streak=0,prev="U"
   for e in runEvents {
    let known=e.side=="L" || e.side=="R"
    if known {streak=e.side==prev ? streak+1:1;longest=max(longest,streak);if prev != "U"{pairs+=1;if prev != e.side{switches+=1}}}else{streak=0}
    prev=known ? e.side:"U"
   }
   let contactX=runEvents.map{e in all.last(where:{$0.time<=e.time && e.time-$0.time<=0.1 && $0.bodyValid})?.u}
   let gaps=zip(runEvents,runEvents.dropFirst()).map{$1.time-$0.time}
   var trend=[Trend]()
   if gaps.count>=8 {
    for i in 8...gaps.count {
     let part=Array(gaps[(i-8)..<i]),xx=Array(contactX[(i-7)...i]).compactMap{$0}
     let spread:Double?=xx.count==8 ? (q(xx,0.9)!-q(xx,0.1)!):nil
     trend.append(Trend(time:runEvents[i].time,jitter:(q(part,0.75)!-q(part,0.25)!)*1000,spread:spread))
    }
   }
   var errors=[Double]()
   if gaps.count>=5 {for i in 4..<gaps.count {errors.append(abs(gaps[i]-q(Array(gaps[(i-4)..<i]),0.5)!)*1000)}}
   let xs=Array(contactX.suffix(20)).compactMap{$0}
   let metrics:[Double?]=[errors.count>=4 ? q(Array(errors.suffix(20)),0.5):nil,cv(flights.map(\.rise)),xs.count>=5 ? q(xs,0.9)!-q(xs,0.1)!:nil]
   var seenHistory=Set<String>()
   let history=input.history.filter{$0.contextKey==input.contextKey && $0.definitionsVersion==input.definitionsVersion && $0.sampleCount>=20 && [$0.jitter,$0.riseVariation,$0.sideSpread].allSatisfy{$0.isFinite && $0>=0} && seenHistory.insert($0.id).inserted}
   let enough=history.count>=5
   let base:[Double?]=enough ? [q(history.map(\.jitter),0.5),q(history.map(\.riseVariation),0.5),q(history.map(\.sideSpread),0.5)]:[nil,nil,nil]
   return Snapshot(time:now,timing:timing,flights:flights,launches:launches,heat:heat,heatPath:path,heatValidSeconds:validSeconds,heatOutsideSeconds:outside,centerPercent:validSeconds>0 ? insideSeconds/validSeconds*100:nil,sideSpread:weightedQ(weighted,0.9).flatMap{hi in weightedQ(weighted,0.1).map{hi-$0}},speed:speeds,currentSpeed:currentSpeed,recentPeak:speeds.map(\.y).max(),recoveryPath:recovery,episodes:episodes,ongoingStart:active,ongoingContacts:active.map{start in events.filter{$0.time>start}.count} ?? 0,censoredEpisodes:censored,sequence:Array(runEvents.suffix(12)),switches:switches,pairs:pairs,longestRun:longest,unknownContacts:runEvents.filter{$0.side=="U"}.count,trend:trend,earlyTrend:gaps.count>=16 ? trend.first:nil,latestTrend:gaps.count>=16 ? trend.last:nil,currentMetrics:metrics,baselineMetrics:base,baselineCount:history.count)
  }
 }
}
