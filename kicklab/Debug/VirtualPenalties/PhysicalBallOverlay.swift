#if DEBUG && BALL_DETECTION_DEBUG
import SwiftUI
import QuartzCore

/// Draws the camera-driven copy on the calibrated wall. It follows the camera's
/// line of sight; a single camera does not recover a separate player's viewpoint.
struct PhysicalBallOverlay: View {
    @ObservedObject var live: RealPenaltySession
    @ObservedObject var keeper: KeeperScene
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/60,paused:!live.armed || !live.showTrackedBall)) { _ in
            let now=CACurrentMediaTime()
            Canvas { context,size in
                guard live.armed,!keeper.reviewActive,live.showTrackedBall,let cameraBoard=live.calibratedBoard,
                      keeper.projectedGoalCorners.count==4 else { return }
                let c=keeper.projectedGoalCorners
                guard let output=WallBoard(topLeft:c[0],topRight:c[1],bottomRight:c[2],bottomLeft:c[3]),
                      let frame=live.flightFrame(at:now) else { return }
                func project(_ p: SIMD2<Double>) -> CGPoint {
                    let uv=cameraBoard.boardPoint(CGPoint(x:p.x,y:p.y))
                    let screen=output.imagePoint(u:uv.x,v:uv.y)
                    return CGPoint(x:screen.x*size.width,y:screen.y*size.height)
                }
                let centre=project(frame.image)
                let rx=project(frame.image+[frame.cameraDiameter/2,0])
                let ry=project(frame.image+[0,frame.cameraDiameter*live.imageAspect/2])
                // Inscribe the copy in the mapped footprint, keeping its camera
                // silhouette smaller than the real ball. No minimum-size upscaling.
                let dx=CGVector(dx:rx.x-centre.x,dy:rx.y-centre.y),dy=CGVector(dx:ry.x-centre.x,dy:ry.y-centre.y)
                let aa=dx.dx*dx.dx+dx.dy*dx.dy,cc=dy.dx*dy.dx+dy.dy*dy.dy,bb=dx.dx*dy.dx+dx.dy*dy.dy
                let radius=sqrt(max(0,(aa+cc-sqrt((aa-cc)*(aa-cc)+4*bb*bb))/2))*0.90
                guard centre.x.isFinite,centre.y.isFinite,radius.isFinite,radius>=2,
                      radius<size.height*0.12 else { return }
                if let previous=live.flightFrame(at:now-0.035) {
                    let p=project(previous.image)
                    if p.x.isFinite,p.y.isFinite,hypot(p.x-centre.x,p.y-centre.y)<size.width*0.2 {
                        var trail=Path();trail.move(to:p);trail.addLine(to:centre)
                        context.stroke(trail,with:.color(.yellow.opacity(0.75)),
                                       style:StrokeStyle(lineWidth:max(1,radius*0.15),lineCap:.round))
                    }
                }
                context.opacity=frame.opacity
                if !keeper.ballSpinFrames.isEmpty {
                    let spin=Int(now*24)%keeper.ballSpinFrames.count
                    context.draw(Image(decorative:keeper.ballSpinFrames[spin],scale:1),
                        in:CGRect(x:centre.x-radius,y:centre.y-radius,width:radius*2,height:radius*2))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
#endif
