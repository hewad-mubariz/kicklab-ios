#if DEBUG
import Foundation
import simd

/// Short gestures after recovery. They never restart a dive or alter the result.
nonisolated enum KeeperOutcomeMotion {
    static func pose(library: MotionLibrary,result: ShotOutcome,time: Double,duration: Double) -> [BonePose] {
        let idle=library.clips["ready"]!.pose(0)
        var pose=idle
        let envelope=smooth(Float(time/0.25))*(1-smooth(Float((time-duration+0.35)/0.35)))
        guard envelope>0 else { return pose }
        func turn(_ name: String,_ angle: Float,_ axis: SIMD3<Float>) {
            let joint=library.index(name),world=library.world(pose)
            let parent=library.rotationOf(world[library.parents[joint]])
            pose[joint].rotation=simd_normalize(parent.inverse*simd_quatf(angle:angle,axis:axis)*parent*pose[joint].rotation)
        }
        switch result {
        case .caught,.parried,.blocked:
            // One compact fist pump, with the other glove close to the chest.
            let pump=sin(Float(clamp((time-0.25)/0.8,0,1)) * .pi)
            library.reach("R",target:[-0.37,1.44+pump*0.28,0.30],pose:&pose)
            library.reach("L",target:[0.17,1.15,0.42],pose:&pose)
            turn("Head",-0.10,[1,0,0])
            // Curl each finger towards its palm using the rig's local bend axis.
            for finger in 1...4 { for suffix in ["","1","2"] {
                let joint=library.index("R_Finger\(finger)\(suffix)")
                pose[joint].rotation=simd_normalize(pose[joint].rotation*simd_quatf(angle:1.0,axis:[0,0,1]))
            } }
        case .goal:
            // Drop the head/shoulders, one glove to the forehead, then a head shake.
            turn("Spine2",0.10,[1,0,0])
            turn("Head",0.30,[1,0,0])
            turn("Head",sin(Float(time)*6)*0.13,[0,1,0])
            library.reach("L",target:[0.30,0.90,0.12],pose:&pose)
            library.reach("R",target:[-0.22,1.68,0.22],pose:&pose)
        case .over,.woodwork:
            turn("Head",-0.20,[1,0,0])
        case .wide:
            turn("Head",0.16,[0,1,0])
        case .pending:
            return idle
        }
        return zip(idle,pose).map { $0.blended(to:$1,fraction:envelope) }
    }
}
#endif
