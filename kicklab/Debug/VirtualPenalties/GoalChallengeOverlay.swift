#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import QuartzCore

/// Goal-space graphics are mapped to the exact goal opening used in calibration.
struct GoalChallengeOverlay: View {
    @ObservedObject var session: GoalChallengeSession
    @ObservedObject var keeper: KeeperScene
    let size: CGSize
    var previewTime: Double? = nil
    private let gold=Color(red:1,green:0.80,blue:0.22)
    private let cyan=Color(red:0.25,green:0.92,blue:1)
    private let green=Color(red:0.3,green:1,blue:0.60)
    private var goal: CGRect {
        let p=keeper.projectedGoalCorners
        guard p.count==4 else { return .zero }
        return CGRect(x:p[0].x*size.width,y:p[0].y*size.height,
                      width:(p[1].x-p[0].x)*size.width,height:(p[3].y-p[0].y)*size.height)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:!session.running)) { _ in
            let now=previewTime ?? CACurrentMediaTime()
            let rect=goal
            let last=session.round?.shots.last
            let recent=last.map { now-$0.confirmedAt<1.6 } ?? false
            ZStack {
                if session.mode == .topBins {
                    ForEach(GoalChallengeRules.bins) { bin in
                        let hit=recent && last?.bin == bin.id
                        let diameter=rect.width*GoalChallengeRules.binRadius*2
                        let color=bin.points==100 ? gold:cyan
                        ZStack {
                            Circle().fill(.black.opacity(0.60))
                            Circle().stroke(color.opacity(0.2),lineWidth:diameter*0.16)
                            Circle().stroke(hit ? .white:color,lineWidth:diameter*0.045)
                                .shadow(color:color.opacity(0.85),radius:diameter*0.10)
                            Text("\(bin.points)").font(.system(size:diameter*0.32,weight:.black,design:.rounded))
                                .foregroundStyle(hit ? .white:color)
                        }
                        .frame(width:diameter,height:diameter)
                        .scaleEffect(hit ? 1.1:1)
                        .position(x:rect.minX+bin.u*rect.width,y:rect.minY+bin.v*rect.height)
                    }
                } else if session.mode == .findSpace {
                    let centre=session.blockerCentre(at:now)
                    let left=(centre-GoalChallengeRules.blockerWidth/2)*rect.width
                    let right=(centre+GoalChallengeRules.blockerWidth/2)*rect.width
                    gap(CGRect(x:rect.minX,y:rect.minY,width:left,height:rect.height),arrow:"chevron.left.2")
                    gap(CGRect(x:rect.minX+right,y:rect.minY,width:rect.width-right,height:rect.height),arrow:"chevron.right.2")
                    RoundedRectangle(cornerRadius:8)
                        .fill(Color.orange.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.orange.opacity(0.65),lineWidth:2))
                        .frame(width:right-left,height:rect.height)
                        .position(x:rect.minX+centre*rect.width,y:rect.midY)

                }
                // A cross identifies the measured real contact without adding a fake football.
                if recent,let last {
                    Image(systemName:"plus").font(.system(size:size.height*0.07,weight:.light))
                        .foregroundStyle(last.points>0 ? .white:.orange)
                        .shadow(color:.black,radius:3)
                        .position(x:rect.minX+last.u*rect.width,y:rect.minY+last.v*rect.height)
                }
                VStack(spacing:5) {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:0) {
                            Text("SCORE").font(.system(size:size.height*0.025,weight:.bold))
                            Text("\(session.round?.score ?? 0)").font(.system(size:size.height*0.075,weight:.black,design:.rounded))
                                .foregroundStyle(gold).monospacedDigit()
                        }
                        Spacer()
                        Text(session.title.uppercased()).font(.system(size:size.height*0.04,weight:.black,design:.rounded))
                            .tracking(1)
                        Spacer()
                        VStack(alignment:.trailing,spacing:6) {
                            Text("\(session.round?.remaining ?? 5) SHOTS LEFT")
                                .font(.system(size:size.height*0.027,weight:.heavy,design:.rounded))
                            HStack(spacing:7) {
                                ForEach(0..<5) { index in
                                    let shots=session.round?.shots ?? []
                                    Circle().fill(index<shots.count ? (shots[index].points>0 ? green:.orange):.white.opacity(0.18))
                                        .frame(width:size.height*0.025,height:size.height*0.025)
                                        .overlay(Circle().stroke(.white.opacity(0.6),lineWidth:1))
                                }
                            }
                        }
                    }
                    Spacer()
                    if session.finished {
                        VStack(spacing:8) {
                            Text("ROUND COMPLETE").font(.system(size:size.height*0.055,weight:.black,design:.rounded))
                            Text("\(session.round?.score ?? 0) POINTS").font(.system(size:size.height*0.08,weight:.black,design:.rounded)).foregroundStyle(gold)
                            Text("Start a new round on the phone").font(.system(size:size.height*0.025,weight:.semibold))
                        }.padding(size.height*0.04).background(.black.opacity(0.9),in:RoundedRectangle(cornerRadius:18))
                        Spacer()
                    } else if recent,let last {
                        Text(last.label).font(.system(size:size.height*0.09,weight:.black,design:.rounded))
                            .foregroundStyle(last.points>0 ? gold:.orange)
                            .shadow(color:.black,radius:4)
                            .shadow(color:last.points>0 ? gold.opacity(0.8):.clear,radius:12)
                        Spacer()
                    }
                    Text(session.finished ? session.mode?.instruction ?? "" : recent ? "Retrieve the ball" : session.mode == .topBins ? "AIM FOR A RING" : "SHOOT THROUGH THE GREEN OPENING")
                        .font(.system(size:size.height*0.03,weight:.heavy,design:.rounded))
                        .tracking(1).padding(.horizontal,18).padding(.vertical,7)
                        .background(.black.opacity(0.85),in:Capsule())
                }.padding(.horizontal,size.width*0.065).padding(.top,size.height*0.035).padding(.bottom,size.height*0.025)
            }.foregroundStyle(.white)
        }.allowsHitTesting(false)
    }
    private func gap(_ rect: CGRect,arrow: String) -> some View {
        ZStack {
            Rectangle().fill(green.opacity(0.12))
            Rectangle().stroke(green,lineWidth:2).shadow(color:green.opacity(0.8),radius:6)
            if rect.width>size.height*0.11 {
                Image(systemName:arrow).font(.system(size:min(rect.width*0.3,size.height*0.065),weight:.heavy))
                    .foregroundStyle(green)
            }
        }.frame(width:max(0,rect.width),height:rect.height).position(x:rect.midX,y:rect.midY)
    }
}
#endif
