#if DEBUG
import Foundation
import simd

/// Camera observations mapped onto the goal plane. Depth is relative to the
/// calibrated wall. Replay depth is illustrative; the hit itself is measured.
nonisolated struct PhysicalShotPoint {
    let time: Double
    let goal: SIMD2<Float>
    let depth: Float
}

nonisolated enum PhysicalShotReview {
    static func build(library: MotionLibrary,points: [PhysicalShotPoint],
                      contact: Double,hit: SIMD2<Float>,radius: Float,
                      motion: PhysicalKeeperMotion?,motionStarted: Double,
                      recordedPose: [BonePose]?=nil,recordedOffset: SIMD3<Float> = .zero,
                      requireRecordedPose: Bool=false) -> ShotReplay? {
        let incoming=points.filter { $0.time<=contact && contact-$0.time<=0.7 }
        guard incoming.count>=3,let first=incoming.first,
              contact-first.time>=0.07,hit.x.isFinite,hit.y.isFinite else { return nil }
        let idle=library.clips["ready"]!
        func body(_ t: Double) -> (pose:[BonePose],offset:SIMD3<Float>) {
            guard let motion,t>=motionStarted else { return (idle.pose(0),.zero) }
            return motion.frame(t-motionStarted)
        }
        // Live results must use the pose submitted for this wall-clock instant.
        // A later refined animation must not manufacture an earlier save.
        let atHit=recordedPose.map { (pose:$0,offset:recordedOffset) }
            ?? (requireRecordedPose ? (pose:idle.pose(0),offset:SIMD3<Float>.zero):body(contact))
        let hasContactPose = !requireRecordedPose || recordedPose != nil
        let world=library.world(atHit.pose)
        let palms=["L","R"].map { library.palm($0,in:world)+atHit.offset }
        let r=clamp(radius,0.10,0.32)
        func separation(_ p: SIMD3<Float>) -> Float { simd_length(SIMD2(p.x,p.y)-hit) }
        let inside=abs(hit.x)+r<3.66 && hit.y>=0 && hit.y+r<2.44
        let hand=palms.enumerated().min { separation($0.element)<separation($1.element) }!
        let handTouch=hasContactPose && motion != nil && separation(hand.element)<r+0.065
        let bodyTouch=hasContactPose && ["Spine2","Pelvis"].contains {
            separation(library.position($0,in:world)+atHit.offset)<r+0.13
        }
        let result: ShotOutcome
        if !inside {
            result=hit.y>=2.44-r ? .over:.wide
        } else if handTouch {
            let centre=(palms[0]+palms[1])/2
            let grip=simd_distance(palms[0],palms[1])
            result=motion!.central && palms.allSatisfy { separation($0)<r+0.065 }
                && separation(centre)<r*0.65 && grip<2*r+0.12 ? .caught:.parried
        } else if bodyTouch { result = .blocked }
        else { result = .goal }
        // This is the virtual keeper's coverage at the measured wall-contact
        // time, not proof that a physical goalkeeper touched the real ball.
        let saved=[ShotOutcome.caught,.parried,.blocked].contains(result)
        let z: Float=saved ? hand.element.z:-0.35
        let impact=SIMD3<Float>(hit.x,max(0.11,hit.y),z)
        let contactTime=contact-first.time
        let end=contactTime+1.05
        var physics: GoalBallPhysics?
        var frames=[ReplayFrame]()
        let catchOffset=impact-(palms[0]+palms[1])/2
        var rotation=simd_quatf(angle:0,axis:[1,0,0])
        for step in 0...Int(ceil(end*120)) {
            let t=Double(step)/120,absolute=first.time+t,frame=body(absolute)
            var ball: SIMD3<Float>
            if t<contactTime {
                let next=incoming.firstIndex { $0.time>=absolute }
                let a: PhysicalShotPoint,b: PhysicalShotPoint
                if let next,next>0 { a=incoming[next-1];b=incoming[next] }
                else if next==0 { a=first;b=first }
                else {
                    a=incoming.last!
                    b=PhysicalShotPoint(time:contact,goal:hit,depth:1)
                }
                let f=Float(clamp((absolute-a.time)/max(0.00001,b.time-a.time),0,1))
                let p=a.goal+(b.goal-a.goal)*f,q=a.depth+(b.depth-a.depth)*f
                ball=[p.x,max(0.11,p.y),z+max(0,1-q)*5]
            } else if result == .caught {
                let world=library.world(frame.pose)
                ball=(library.palm("L",in:world)+library.palm("R",in:world))/2+frame.offset+catchOffset
            } else {
                if physics == nil {
                    let velocity: SIMD3<Float>=saved ? [hit.x<0 ? -3:3,1.2,4]:[0,0,-5]
                    physics=GoalBallPhysics(position:impact,velocity:velocity)
                }
                physics!.step(time:t,dt:1/120)
                ball=physics!.position
            }
            rotation=simd_quatf(angle:Float(t)*8,axis:simd_normalize(SIMD3<Float>(1,0.2,0)))
            frames.append(ReplayFrame(time:t,pose:frame.pose,offset:frame.offset,ball:ball,
                ballRotation:rotation,outcome:t<contactTime ? .pending:result,net:physics?.impacts ?? []))
        }
        var settings=ShotSettings();settings.x=hit.x;settings.y=hit.y
        return ShotReplay(settings:settings,action:motion?.action ?? "Late read",
                          frames:frames,contactTime:contactTime,decisionTime:contactTime,outcome:result)
    }
}
#endif
