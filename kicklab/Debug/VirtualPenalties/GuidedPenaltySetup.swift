#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI

struct PenaltySetupRing: View {
    let number: Int
    var progress: Double=0
    var complete=false
    var active=true
    private let lime=Color(red:0.76,green:0.98,blue:0.32)
    var body: some View {
        GeometryReader { geometry in
            let size=geometry.size.width
            ZStack {
                Circle().fill(.black.opacity(0.9))
                Circle().stroke(active || complete ? lime : .white.opacity(0.4),lineWidth:size*0.035)
                if active && !complete {
                    Circle().trim(from:0,to:progress)
                        .stroke(.white,style:StrokeStyle(lineWidth:size*0.09,lineCap:.round))
                        .rotationEffect(.degrees(-90))
                }
                if complete {
                    Image(systemName:"checkmark").font(.system(size:size*0.38,weight:.heavy)).foregroundStyle(lime)
                } else {
                    // A numeral rather than a projected football avoids adding
                    // a fake ball to the camera's calibration observations.
                    Text("\(number)").font(.system(size:size*0.35,weight:.heavy,design:.rounded)).foregroundStyle(.white)
                }
            }
        }
        .accessibilityLabel(complete ? "Spot \(number) complete" : "Spot \(number), \(Int(progress*100)) percent")
    }
}

/// Progress stays at the held ball. The halo is larger than the size accepted
/// by PhysicalCalibrationHold; the centre cue clears before size measurement.
struct PenaltyWallHoldMarker: View {
    let number: Int
    let progress: Double
    let measuring: Bool
    var body: some View {
        GeometryReader { geometry in
            let side=geometry.size.width
            ZStack {
                Circle().fill(.black.opacity(0.94))
                Circle().stroke(Color(red:0.76,green:0.98,blue:0.32).opacity(0.55),lineWidth:side*0.025)
                Circle().trim(from:0,to:progress)
                    .stroke(.white,style:StrokeStyle(lineWidth:side*0.065,lineCap:.round))
                    .rotationEffect(.degrees(-90))
                if !measuring {
                    Image(systemName:"plus").font(.system(size:side*0.16,weight:.bold)).foregroundStyle(.white)
                }
                Text(measuring ? "HOLD STILL" : "BALL HERE")
                    .font(.system(size:side*0.14,weight:.heavy,design:.rounded))
                    .foregroundStyle(.white).offset(y:side*0.67)
            }
        }
    }
}

/// The wall and phone share the same ordered targets and measured hold progress.
struct GuidedPenaltyProjectorOverlay: View {
    @ObservedObject var live: RealPenaltySession
    @ObservedObject var keeper: KeeperScene
    let size: CGSize
    private var points: [CGPoint] { keeper.projectedGoalCorners }
    private var targets: [CGPoint] {
        guard points.count==4,let board=WallBoard(topLeft:points[0],topRight:points[1],bottomRight:points[2],bottomLeft:points[3]) else { return [] }
        return PhysicalCalibrationTarget.points.map { board.imagePoint(u:$0.x*3,v:$0.y*2) }
    }
    private func screen(_ point: CGPoint) -> CGPoint { CGPoint(x:point.x*size.width,y:point.y*size.height) }
    var body: some View {
        ZStack {
            if live.phase == .finding,points.count==4 {
                // Only the white discs change during the blink. The goal,
                // backing discs and instruction stay fixed for differencing.
                ForEach(0..<4,id:\.self) { index in
                    ZStack {
                        Circle().fill(.black).frame(width:size.height*0.11,height:size.height*0.11)
                        if live.searchDotsVisible {
                            Circle().fill(.white).frame(width:size.height*0.07,height:size.height*0.07)
                        }
                    }.position(screen(points[index]))
                }
            }
            if live.phase == .corners,points.count==4 {
                ForEach(0..<4,id:\.self) { index in
                    PenaltySetupRing(number:index+1,complete:index<live.corners.count,active:index==live.corners.count)
                        .frame(width:size.height*0.09,height:size.height*0.09)
                        .position(screen(points[index]))
                }
            }
            if live.phase == .reference,targets.count==PhysicalCalibrationTarget.points.count {
                ForEach(targets.indices,id:\.self) { index in
                    if index<=live.completedHolds.count {
                        let complete=index<live.completedHolds.count
                        let diameter=complete ? size.height*0.065 : abs(points[1].x-points[0].x)*size.width*0.15
                        if complete {
                            Image(systemName:"checkmark").font(.system(size:diameter*0.6,weight:.heavy))
                                .foregroundStyle(Color(red:0.76,green:0.98,blue:0.32))
                                .position(screen(targets[index]))
                        } else {
                            PenaltyWallHoldMarker(number:index+1,progress:live.referenceProgress,measuring:live.holdTargetHidden)
                                .frame(width:diameter,height:diameter)
                                .position(screen(targets[index]))
                        }
                    }
                }
            }
            VStack(spacing:size.height*0.012) {
                Text(live.setupTitle.uppercased())
                    .font(.system(size:size.height*0.042,weight:.heavy,design:.rounded))
                Text(projectorInstruction)
                    .font(.system(size:size.height*0.029,weight:.semibold))
                    .multilineTextAlignment(.center)

            }
            .foregroundStyle(.white)
            .padding(.horizontal,size.height*0.04).padding(.vertical,size.height*0.018)
            .background(.black.opacity(0.92),in:RoundedRectangle(cornerRadius:size.height*0.022))
            .frame(maxWidth:size.width*0.88)
            .position(x:size.width/2,y:size.height*0.135)
            if live.phase == .countdown {
                Text("\(live.countdown ?? 5)")
                    .font(.system(size:size.height*0.20,weight:.black,design:.rounded))
                    .foregroundStyle(.white)
                    .frame(width:size.height*0.29,height:size.height*0.29)
                    .background(.black.opacity(0.92),in:Circle())
                    .position(x:size.width/2,y:size.height*0.59)
            }
        }
        .allowsHitTesting(false)
    }
    private var projectorInstruction: String {
        switch live.phase {
        case .inspect: return "On the phone, choose Start guided setup"
        case .finding: return "Stay still beside the phone until a numbered target appears"
        case .focusing: return "Stand aside · focusing on the goal"
        case .corners: return "Tap the highlighted corner in the phone’s camera picture"
        case .reference: return live.holdTargetHidden ? "Keep touching the wall until the ring fills" : "Hold your ball against the wall in the centre ring"
        case .countdown: return "Take the ball back to your shooting position"
        case .ready: return "Tap Start on the phone"
        case .playing: return ""
        }
    }
}

struct PenaltySetupSteps: View {
    @ObservedObject var live: RealPenaltySession
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(live.setupTitle).font(.system(size:17,weight:.bold,design:.rounded))
            Text(live.message).font(.system(size:12,weight:.medium))
                .fixedSize(horizontal:false,vertical:true)
            if live.phase == .reference || live.phase == .countdown {
                HStack(spacing:9) {
                    ForEach(PhysicalCalibrationTarget.points.indices,id:\.self) { index in
                        PenaltySetupRing(number:index+1,
                            progress:index==live.targetIndex ? live.referenceProgress:0,
                            complete:index<live.completedHolds.count,active:index==live.targetIndex)
                            .frame(width:34,height:34)
                    }
                    Text(live.phase == .countdown ? "Ball measured" : "Fill this ring, then step back")
                        .font(.system(size:12,weight:.semibold))
                }
            } else if live.phase == .finding || live.phase == .focusing {
                HStack { ProgressView().tint(.white);Text("Keep the goal clear").font(.caption) }
            }
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(12)
        .background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }
}
#endif
