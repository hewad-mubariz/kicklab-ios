#if DEBUG
import Foundation
import simd

/// Samples only the keeper's captured pose. This never simulates or displays a
/// ball, manufactures a catch, or precomputes several seconds of goal physics.
nonisolated struct PhysicalKeeperMotion {
    enum Save: String {
        case lowSmother, bodyCatch, highReach, lowDive, midDive, highDive
    }
    let library: MotionLibrary
    private(set) var target: SIMD3<Float>
    let kind: String
    let central: Bool
    let side: String
    let clipStart,rate: Double
    private(set) var reference: SIMD3<Float>
    private var diveRoll: Float=0
    private var diveLift: Float=0
    private var lowDiveWeight: Float=0
    var clip: MotionLibrary.Clip { library.clips[kind]! }
    var duration: Double { (clip.duration-clipStart)/rate+0.45 }
    var reachTime: Double { (clip.contactTime-clipStart)/rate }
    var save: Save {
        if central { return target.y<0.9 ? .lowSmother:target.y>1.85 ? .highReach:.bodyCatch }
        return target.y<0.7 ? .lowDive:target.y>1.8 ? .highDive:.midDive
    }
    var action: String {
        switch save {
        case .lowSmother: return "Low smother attempt"
        case .bodyCatch: return "Body catch attempt"
        case .highReach: return "High reach attempt"
        case .lowDive: return "Low dive \(target.x<0 ? "left":"right")"
        case .midDive: return "Mid-height dive \(target.x<0 ? "left":"right")"
        case .highDive: return "High dive \(target.x<0 ? "left":"right")"
        }
    }

    init(library: MotionLibrary,target point: SIMD2<Float>,lead: Double,maximumRate: Double=2) {
        self.library=library
        central=abs(point.x)<1.05
        kind=central ? (point.y<0.9 ? "low":point.y>1.85 ? "high":"medium") : point.x<0 ? "left":"right"
        side=point.x<0 ? "R":"L"
        let clip=library.clips[kind]!
        let lower=library.clips[point.y<1.425 ? "low":"medium"]!
        let upper=library.clips[point.y<1.425 ? "medium":"high"]!
        let blendWeight=clamp((point.y-(point.y<1.425 ? 0.43:1.425))/(point.y<1.425 ? 0.995:0.885),0,1)
        clipStart=central ? (kind == "low" ? 0.18:0):0.24
        rate=clamp((clip.contactTime-clipStart)/max(0.08,lead),0.75,clamp(maximumRate,0.75,2))
        let pose: [BonePose]
        if central {
            pose=zip(lower.pose(lower.contactTime),upper.pose(upper.contactTime)).map { $0.blended(to:$1,fraction:blendWeight) }
        } else { pose=clip.pose(clip.contactTime) }
        let world=library.world(pose)
        reference=central ? (library.palm("L",in:world)+library.palm("R",in:world))/2 : library.palm(side,in:world)
        target=[point.x,clamp(point.y,0.12,3.2),reference.z]
        configureHeight()
    }

    mutating func refine(_ point: SIMD2<Float>) {
        guard point.x.isFinite,point.y.isFinite else { return }
        // Keep the committed side. New measurements adjust the reach, never
        // reverse a dive or restart its animation clock.
        let x=central ? clamp(point.x,-0.9,0.9) : (point.x*target.x>=0 ? point.x:target.x)
        target.x += clamp(x-target.x,-0.20,0.20)
        target.y += clamp(clamp(point.y,0.12,3.2)-target.y,-0.20,0.20)
        configureHeight()
    }
    private mutating func configureHeight() {
        if central {
            let lower=library.clips[target.y<1.425 ? "low":"medium"]!
            let upper=library.clips[target.y<1.425 ? "medium":"high"]!
            let weight=clamp((target.y-(target.y<1.425 ? 0.43:1.425))/(target.y<1.425 ? 0.995:0.885),0,1)
            let pose=zip(lower.pose(lower.contactTime),upper.pose(upper.contactTime))
                .map { $0.blended(to:$1,fraction:weight) }
            let world=library.world(pose)
            reference=(library.palm("L",in:world)+library.palm("R",in:world))/2
            target.z=reference.z
            return
        }
        let contact=clip.pose(clip.contactTime),world=library.world(contact)
        let hip=library.position("Pelvis",in:world),hand=library.palm(side,in:world)
        let arm=hand-hip
        // A low save collapses onto the side; a high save pushes the hips up.
        // Rotate the captured body towards the reach, preserving bone lengths.
        let hipHeight=clamp(0.36+(target.y-0.22)*0.52,0.36,1.52)
        let desiredY=clamp(target.y-hipHeight,-0.45,0.95)
        let direction: Float=target.x<0 ? -1:1
        let angle=asin(clamp(desiredY/hypot(arm.x,arm.y),-0.8,0.8))
        let original=atan2(arm.y,abs(arm.x))
        diveRoll=clamp(direction*(angle-original),-0.65,0.65)
        diveLift=hipHeight-hip.y
        lowDiveWeight=1-smooth((target.y-0.4)/0.6)
        var adjusted=contact
        rollBody(&adjusted,by:diveRoll)
        reference=library.palm(side,in:library.world(adjusted))
        target.z=reference.z
    }
    private func rollBody(_ pose: inout [BonePose],by angle: Float) {
        let root=library.index("Pelvis")
        let basis=library.rotationOf(library.root)
        let rotation=simd_quatf(angle:angle,axis:[0,0,1])
        pose[root].rotation=simd_normalize(basis.inverse*rotation*basis*pose[root].rotation)
    }
    private func lowerTrailingFoot(_ side: String,weight: Float,offset: SIMD3<Float>,pose: inout [BonePose]) {
        guard weight>0.001 else { return }
        let foot=library.index(side+"_Foot")
        let original=library.world(pose),rotation=library.rotationOf(original[foot])
        var goal=library.position(side+"_Foot",in:original)
        // A low collapse keeps the trailing leg near the grass instead of
        // retaining the capture's high scissor kick.
        goal.y += (max(0.10-offset.y,goal.y-0.85)-goal.y)*weight
        for _ in 0..<5 {
            for joint in [library.index(side+"_Calf"),library.index(side+"_Thigh")] {
                let world=library.world(pose)
                let origin=SIMD3<Float>(world[joint].columns.3.x,world[joint].columns.3.y,world[joint].columns.3.z)
                let end=library.position(side+"_Foot",in:world)
                guard simd_length(end-origin)>0.001,simd_length(goal-origin)>0.001 else { continue }
                let turn=simd_quatf(from:simd_normalize(end-origin),to:simd_normalize(goal-origin))
                let parent=library.rotationOf(world[library.parents[joint]])
                pose[joint].rotation=simd_normalize(parent.inverse*turn*parent*pose[joint].rotation)
            }
        }
        let world=library.world(pose)
        pose[foot].rotation=simd_normalize(library.rotationOf(world[library.parents[foot]]).inverse*rotation)
    }
    func frame(_ elapsed: Double) -> (pose:[BonePose],offset:SIMD3<Float>) {
        let local=clamp(clipStart+max(0,elapsed)*rate,clipStart,clip.duration)
        let idle=library.clips["ready"]!.pose(max(0,elapsed))
        let lower=library.clips[target.y<1.425 ? "low":"medium"]!
        let upper=library.clips[target.y<1.425 ? "medium":"high"]!
        let weight=clamp((target.y-(target.y<1.425 ? 0.43:1.425))/(target.y<1.425 ? 0.995:0.885),0,1)
        var pose=central
            ? zip(lower.pose(local*lower.contactTime/clip.contactTime),upper.pose(local*upper.contactTime/clip.contactTime)).map { $0.blended(to:$1,fraction:weight) }
            : clip.pose(local)
        let progress=smooth(Float((local-clipStart)/(clip.contactTime-clipStart)))
        let air=smooth(Float((local-0.40)/0.46))*(1-smooth(Float((local-1.02)/0.50)))
        if !central { rollBody(&pose,by:diveRoll*air) }
        let blend=smooth(Float(elapsed/0.09))
        pose=zip(idle,pose).map { $0.blended(to:$1,fraction:blend) }
        var offset=SIMD3<Float>(clamp(target.x-reference.x,-0.65,0.65)*progress,
            central ? 0:diveLift*air,0)
        if !central {
            lowerTrailingFoot(side == "L" ? "R":"L",weight:lowDiveWeight*air,offset:offset,pose:&pose)
        }
        var world=library.world(pose)
        let floor=["L_Foot","R_Foot","L_Calf","R_Calf","Pelvis","Spine2","Head"]
            .map { library.position($0,in:world).y }.min()!
        offset.y=max(offset.y,0.035-floor)
        let envelope=smooth(Float((local-(clip.contactTime-0.3))/0.22))*(1-smooth(Float((local-(clip.contactTime+0.12))/0.32)))
        if envelope>0.001 {
            for hand in central || lowDiveWeight>0.5 ? ["L","R"]:[side] {
                world=library.world(pose)
                let palm=library.palm(hand,in:world)+offset
                var demand=target
                if central { demand.x += hand == "L" ? 0.06 : -0.06 }
                let delta=demand-palm
                let bounded=delta*min(1,0.28/max(0.001,simd_length(delta)))*envelope
                library.reach(hand,target:library.position(hand+"_Hand",in:world)+bounded,pose:&pose)
            }
        }
        let recovery=smooth(Float((elapsed-(clip.duration-clipStart)/rate)/0.45))
        if recovery>0 { pose=zip(pose,idle).map { $0.blended(to:$1,fraction:recovery) };offset *= 1-recovery }
        return (pose,offset)
    }
}

/// A forward-only clock for an approaching physical ball. Refined arrival
/// times change the remaining reach, never restart the save. The short contact
/// hold absorbs depth-estimate error without beginning recovery before impact.
nonisolated struct PhysicalSaveTiming {
    let startedAt,initialArrival,reachTime,duration,maximumSlope,holdDuration: Double
    private(set) var arrival: Double
    private(set) var elapsed=0.0
    private var previous: Double

    init(motion: PhysicalKeeperMotion,startedAt: Double,arrival: Double) {
        self.startedAt=startedAt;self.initialArrival=arrival;self.arrival=arrival
        reachTime=motion.reachTime;duration=motion.duration
        maximumSlope=2/max(0.75,motion.rate)
        holdDuration=motion.central ? 0.16:0.06
        previous=startedAt
    }
    mutating func refine(arrival proposed: Double,observedAt: Double) {
        guard proposed.isFinite,observedAt.isFinite,proposed>observedAt,
              observedAt<=arrival+0.16,elapsed<=reachTime else { return }
        arrival += clamp(clamp(proposed,initialArrival-0.12,initialArrival+0.18)-arrival,-0.045,0.045)
    }
    mutating func advance(to time: Double) -> Double {
        guard time.isFinite,time>previous else { return elapsed }
        let dt=time-previous
        if elapsed<reachTime {
            let slope=clamp((reachTime-elapsed)/max(0.025,arrival-previous),0.15,maximumSlope)
            elapsed=min(reachTime,elapsed+dt*slope)
        } else if time>arrival+holdDuration {
            elapsed=min(duration,elapsed+max(0,time-max(previous,arrival+holdDuration)))
        }
        previous=time
        return elapsed
    }
    var recoveryEnds: Double {
        if elapsed>=reachTime {
            return max(previous,arrival+holdDuration)+max(0,duration-elapsed)
        }
        return max(arrival,previous+(reachTime-elapsed)/maximumSlope)+holdDuration+duration-reachTime
    }
}

/// Continue a confirmed two-hand catch into a short chest cradle. The ball is
/// drawn only while the actual palms form a grip; separated hands cannot
/// support a ball floating at their midpoint.
nonisolated enum PhysicalCatchGrip {
    static func apply(library: MotionLibrary,pose: [BonePose],radius: Float,
                      initialRelativeCentre: SIMD3<Float>,time: Double,remaining: Double) -> [BonePose] {
        var result=pose
        let world=library.world(pose),chest=library.position("Spine2",in:world)
        let settled=SIMD3<Float>(0,-0.12,0.30)
        let centre=chest+initialRelativeCentre+(settled-initialRelativeCentre)*smooth(Float(time/0.35))
        let weight=smooth(Float(time/0.14))*smooth(Float(remaining/0.25))
        for side in ["L","R"] {
            let world=library.world(result)
            let desired=centre+SIMD3<Float>(side == "L" ? radius*0.65:-radius*0.65,0,0)
            let delta=desired-library.palm(side,in:world)
            let bounded=delta*min(1,0.35/max(0.001,simd_length(delta)))*weight
            library.reach(side,target:library.position(side+"_Hand",in:world)+bounded,pose:&result)
        }
        return result
    }
    static func centre(library: MotionLibrary,pose: [BonePose],radius: Float) -> SIMD3<Float>? {
        let world=library.world(pose)
        let left=library.palm("L",in:world),right=library.palm("R",in:world)
        guard simd_distance(left,right)<2*radius+0.10,abs(left.z-right.z)<radius+0.10 else { return nil }
        return (left+right)/2
    }
}

nonisolated enum PhysicalKeeperPreparation {
    /// A small set-position change while a first trajectory is being checked.
    /// It never commits a side, lifts the boots, or claims a save.
    static func pose(library: MotionLibrary,target: SIMD2<Float>,weight: Float,idleTime: Double) -> [BonePose] {
        let idle=library.clips["ready"]!.pose(idleTime.truncatingRemainder(dividingBy:library.clips["ready"]!.duration))
        let crouch=library.clips["medium"]!.pose(0.16)
        var pose=zip(idle,crouch).map { $0.blended(to:$1,fraction:0.22*weight) }
        let spine=library.index("Spine2")
        pose[spine].rotation *= simd_quatf(angle:clamp(-target.x*0.025,-0.06,0.06)*weight,axis:[0,0,1])
        return pose
    }
}
#endif
