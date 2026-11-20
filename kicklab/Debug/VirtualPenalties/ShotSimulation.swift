#if DEBUG
import Foundation
import simd

nonisolated func clamp<T: Comparable>(_ x: T, _ a: T, _ b: T) -> T { min(max(x, a), b) }
nonisolated func smooth(_ x: Float) -> Float { let u = clamp(x, 0, 1); return u*u*(3-2*u) }

nonisolated struct BonePose {
    var translation: SIMD3<Float>
    var rotation: simd_quatf
    var scale: SIMD3<Float>
    init(_ values: [Float]) {
        translation = .init(values[0], values[1], values[2])
        rotation = simd_quatf(vector: .init(values[3], values[4], values[5], values[6]))
        scale = .init(values[7], values[8], values[9])
    }
    var matrix: simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.0 *= scale.x; m.columns.1 *= scale.y; m.columns.2 *= scale.z
        m.columns.3 = SIMD4<Float>(translation, 1)
        return m
    }
    func blended(to b: BonePose, fraction f: Float) -> BonePose {
        var p = self
        p.translation += (b.translation-translation)*f
        p.rotation = simd_slerp(rotation, b.rotation, f)
        p.scale += (b.scale-scale)*f
        return p
    }
}

nonisolated struct MotionLibrary: Decodable {
    struct Clip: Decodable {
        let fps: Double
        let duration: Double
        let contactTime: Double
        let frames: [[[Float]]]
        func pose(_ time: Double) -> [BonePose] {
            let f = clamp(time*fps, 0, Double(frames.count-1)), lo = Int(f), hi = min(lo+1,frames.count-1)
            return zip(frames[lo], frames[hi]).map { BonePose($0).blended(to: BonePose($1), fraction: Float(f-Double(lo))) }
        }
    }
    let names: [String]
    let parents: [Int]
    let basis: [Float]
    let clips: [String: Clip]
    let root: simd_float4x4
    private let indices: [String:Int]
    private enum CodingKeys: String,CodingKey { case names,parents,basis,clips }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        names=try c.decode([String].self,forKey:.names);parents=try c.decode([Int].self,forKey:.parents)
        basis=try c.decode([Float].self,forKey:.basis);clips=try c.decode([String:Clip].self,forKey:.clips)
        root=simd_float4x4(columns:(SIMD4(basis[0...3]),SIMD4(basis[4...7]),SIMD4(basis[8...11]),SIMD4(basis[12...15])))
        indices=Dictionary(uniqueKeysWithValues:names.enumerated().map { (String($0.element.split(separator:"/").last!).replacingOccurrences(of:"Bip01_",with:""),$0.offset) })
    }
    func index(_ name: String) -> Int { indices[name]! }
    func world(_ pose: [BonePose]) -> [simd_float4x4] {
        var result = [simd_float4x4](); result.reserveCapacity(names.count)
        for i in names.indices { result.append((parents[i] < 0 ? root : result[parents[i]]) * pose[i].matrix) }
        return result
    }
    func position(_ name: String, in matrices: [simd_float4x4]) -> SIMD3<Float> {
        let v = matrices[index(name)].columns.3; return SIMD3(v.x,v.y,v.z)
    }
    func palm(_ side: String, in matrices: [simd_float4x4]) -> SIMD3<Float> {
        let wrist = position(side+"_Hand", in: matrices), middle = position(side+"_Finger2", in: matrices)
        let across = position(side+"_Finger1", in: matrices)-position(side+"_Finger4", in: matrices)
        var normal = simd_normalize(simd_cross(middle-wrist, across)); if normal.z < 0 { normal = -normal }
        return wrist+(middle-wrist)*0.72+normal*0.126
    }
    // Rotate the shoulder and elbow; preserve bone lengths and captured wrist orientation.
    func reach(_ side: String, target: SIMD3<Float>, pose: inout [BonePose]) {
        let hand = index(side+"_Hand"), chain = [index(side+"_Forearm"), index(side+"_UpperArm")]
        let original = world(pose)
        let wristRotation = rotationOf(original[hand])
        for _ in 0..<5 {
            for joint in chain {
                let ws = world(pose)
                let p = SIMD3<Float>(ws[joint].columns.3.x,ws[joint].columns.3.y,ws[joint].columns.3.z)
                let end = position(side+"_Hand",in: ws)
                guard simd_length(end-p)>0.001, simd_length(target-p)>0.001 else { continue }
                let delta = simd_quatf(from: simd_normalize(end-p), to: simd_normalize(target-p))
                let parentRotation = rotationOf(parents[joint] < 0 ? root : ws[parents[joint]])
                pose[joint].rotation = simd_normalize(parentRotation.inverse * delta * parentRotation * pose[joint].rotation)
            }
        }
        let ws = world(pose)
        pose[hand].rotation = simd_normalize(rotationOf(ws[parents[hand]]).inverse * wristRotation)
    }
    func rotationOf(_ m: simd_float4x4) -> simd_quatf {
        simd_quatf(simd_float3x3(columns: (simd_normalize(SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z)),simd_normalize(SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z)),simd_normalize(SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z)))))
    }
}

nonisolated enum ShotStyle: String, CaseIterable, Identifiable { case driven = "Driven", chip = "Panenka", bounce = "Bounce"; var id: String { rawValue } }
nonisolated enum KeeperRead: String, CaseIterable, Identifiable { case react = "Read shot", left = "Commit left", right = "Commit right"; var id: String { rawValue } }
nonisolated struct ShotSettings {
    var x: Float = 0
    var y: Float = 1.25
    var power: Float = 0.35
    var style: ShotStyle = .driven
    var read: KeeperRead = .react
    var flightTime: Double { style == .chip ? 1.5-Double(power)*0.3 : 0.95-Double(power)*0.45 }
    var kmh: Int { Int(11/flightTime*3.6) }
    let release = 0.55
    func incoming(_ time: Double) -> SIMD3<Float> {
        let t = max(0,time-release), u = Float(t/flightTime)
        let start = SIMD3<Float>(0,0.11,10.65), end = SIMD3<Float>(x,y,-0.35)
        var p = start+(end-start)*u
        if style == .bounce {
            let bounce: Float = 0.68
            if u < bounce {
                let q = u/bounce
                p.y = 0.11 + 0.5*9.81*pow(Float(flightTime)*bounce,2)*q*(1-q)
            } else {
                let q = (u-bounce)/(1-bounce)
                p.y = 0.11+(y-0.11)*q+0.5*9.81*pow(Float(flightTime)*(1-bounce),2)*q*(1-q)
            }
        } else { p.y += 0.5*9.81*pow(Float(flightTime),2)*u*(1-u) }
        p.y = max(0.11,p.y)
        return p
    }
}

nonisolated enum ShotOutcome: String { case pending = "Ball in flight", caught = "Caught", parried = "Parried", blocked = "Blocked", goal = "Goal", wide = "Wide", over = "Over the bar", woodwork = "Woodwork" }
nonisolated struct ReplayFrame {
    let time: Double
    let pose: [BonePose]
    let offset: SIMD3<Float>
    let ball: SIMD3<Float>
    let ballRotation: simd_quatf
    let outcome: ShotOutcome
    let net: [NetImpact]
}
nonisolated struct ShotReplay {
    let settings: ShotSettings
    let action: String
    let frames: [ReplayFrame]
    let contactTime: Double?
    let decisionTime: Double
    let outcome: ShotOutcome
    var duration: Double { frames.last!.time }
    func frame(_ time: Double) -> ReplayFrame {
        let f = clamp(time*120, 0, Double(frames.count-1)), lo = Int(f), hi = min(lo+1,frames.count-1), u = Float(f-Double(lo))
        let a=frames[lo], b=frames[hi]
        let net=a.net.enumerated().map { i,impact in
            var n=impact
            if i<b.net.count { n.depth += (b.net[i].depth-n.depth)*u;n.center += (b.net[i].center-n.center)*u }
            return n
        }
        return ReplayFrame(time: time, pose: zip(a.pose,b.pose).map { $0.blended(to:$1,fraction:u) }, offset:a.offset+(b.offset-a.offset)*u,ball:a.ball+(b.ball-a.ball)*u,ballRotation:simd_slerp(a.ballRotation,b.ballRotation,u),outcome:a.outcome,net:net)
    }
}

nonisolated struct ShotSimulator {
    let library: MotionLibrary
    func build(_ settings: ShotSettings) -> ShotReplay {
        let committed = settings.read != .react
        let direction: Float = committed ? (settings.read == .left ? -1:1) : (settings.x < 0 ? -1:1)
        let central = !committed && abs(settings.x)<1.05
        let predictedHeight=settings.incoming(settings.release+settings.flightTime*0.90).y
        let idle=library.clips["ready"]!
        let planned=SIMD2<Float>(committed ? direction*2.65:settings.x,committed ? 1.1:predictedHeight)
        let estimate=PhysicalKeeperMotion(library:library,target:planned,lead:1)
        let contactEstimate=settings.release+settings.flightTime*Double((10.65-estimate.reference.z)/11)
        let target=settings.incoming(contactEstimate)
        let reaction=settings.release+(committed ? -0.22:0.12)
        // The trial and real-ball game now share the same height-aware body
        // mechanics. A forced commitment keeps its original side and height.
        let motion=PhysicalKeeperMotion(library:library,
            target:committed ? planned:[target.x,target.y],lead:max(0.1,contactEstimate-reaction),maximumRate:1.65)
        let startTime=max(reaction,contactEstimate-motion.reachTime)
        let action=motion.action
        let end=max(6.5,startTime+motion.duration)
        var frames=[ReplayFrame](), outcome=ShotOutcome.pending, contact: Double?
        var flight: GoalBallPhysics?, previousBall=settings.incoming(0)
        var ballRotation=simd_quatf(angle:0,axis:SIMD3<Float>(1,0,0))
        var previousHands=[SIMD3<Float>](), previousBody=[SIMD3<Float>](), catchOffset=SIMD3<Float>.zero
        let dt: Float=1/120
        for step in 0...Int(end*120) {
            let time=Double(step)/120
            let sampled=motion.frame(max(0,time-startTime))
            let pose=time<startTime ? idle.pose(time):sampled.pose
            let offset=time<startTime ? SIMD3<Float>.zero:sampled.offset
            let world=library.world(pose)
            let hands=[library.palm("L",in:world)+offset,library.palm("R",in:world)+offset]
            let body=[library.position("Spine2",in:world)+offset,library.position("Pelvis",in:world)+offset,library.position("L_Foot",in:world)+offset,library.position("R_Foot",in:world)+offset]
            var ball=settings.incoming(time)
            if outcome == .caught {
                ball=(hands[0]+hands[1])/2+catchOffset
            } else if flight != nil {
                flight!.step(time:time,dt:dt)
                ball=flight!.position
                if flight!.woodworkTime != nil && outcome == .pending { outcome = .woodwork }
            } else if time>settings.release && step>0 {
                let touch = hands.indices.first { swept(previousBall-previousHands[$0],ball-hands[$0]) < 0.065 }
                let block = body.indices.first { swept(previousBall-previousBody[$0],ball-body[$0]) < ($0<2 ? 0.26:0.17) }
                if let hand=touch {
                    contact=time
                    let secure=central && simd_length(ball-hands[1-hand])<0.24 && settings.power<0.72
                    outcome=secure ? .caught:.parried
                    if secure { catchOffset=ball-(hands[0]+hands[1])/2 }
                    else { flight=GoalBallPhysics(position:ball,velocity:[(ball.x<0 ? -1:1)*(4+settings.power*3),2,4]) }
                } else if block != nil {
                    contact=time;outcome = .blocked
                    flight=GoalBallPhysics(position:ball,velocity:[(ball.x<0 ? -1:1)*2.8,1.5,4.5])
                } else if let hit=GoalBallPhysics.frameHit(from:previousBall,to:ball) {
                    let velocity=(ball-previousBall)/dt
                    ball=hit.point+hit.normal*0.001
                    flight=GoalBallPhysics(position:ball,velocity:GoalBallPhysics.rebound(velocity,normal:hit.normal,restitution:0.62,friction:0.08))
                    outcome = .woodwork
                } else if ball.z <= -0.35 {
                    flight=GoalBallPhysics(position:ball,velocity:(ball-previousBall)/dt)
                }
            }
            // A goal requires the whole ball to cross the line. A post rebound may
            // still score; outside/roof-net impacts can never turn a miss into a goal.
            if previousBall.z > -0.46 && ball.z <= -0.46 {
                let u=clamp((-0.46-previousBall.z)/(ball.z-previousBall.z),0,1)
                let crossing=previousBall+(ball-previousBall)*u
                if abs(crossing.x)<=3.55 && crossing.y<=2.33 { outcome = .goal }
                else if outcome == .pending { outcome = crossing.y>2.33 ? .over:.wide }
            }
            if outcome != .caught {
                let movement=ball-previousBall
                let ground=GoalBallPhysics.groundHeight(at:ball)
                let roll=SIMD3<Float>(movement.z,0,-movement.x)/GoalBallPhysics.radius
                let angle=ball.y<ground+0.13 ? simd_length(roll):min(simd_length(movement)*0.65,16*dt)
                if angle>0.000001 {
                    let axis=ball.y<ground+0.13 && simd_length(roll)>0.000001 ? simd_normalize(roll):simd_normalize(SIMD3<Float>(-1,settings.x*0.08,0))
                    ballRotation=simd_normalize(simd_quatf(angle:angle,axis:axis)*ballRotation)
                }
            }
            previousBall=ball;previousHands=hands;previousBody=body
            frames.append(ReplayFrame(time:time,pose:pose,offset:offset,ball:ball,ballRotation:ballRotation,outcome:outcome,net:flight?.impacts ?? []))
        }
        return ShotReplay(settings:settings,action:action,frames:frames,contactTime:contact,decisionTime:contactEstimate,outcome:outcome)
    }
    private func swept(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d=b-a, t=clamp(-simd_dot(a,d)/max(0.000001,simd_dot(d,d)),0,1)
        return simd_length(a+d*t)
    }
}

#endif
