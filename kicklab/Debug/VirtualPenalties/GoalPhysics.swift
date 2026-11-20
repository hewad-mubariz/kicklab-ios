#if DEBUG
import Foundation
import simd

/// The visible net and the ball contacts share these finite, curved surfaces.
nonisolated enum NetPanel: Int, CaseIterable {
    case back, left, right, roof
    func point(_ uv: SIMD2<Float>) -> SIMD3<Float> {
        switch self {
        case .back: return [-3.66+7.32*uv.x, 0.06+2.29*uv.y, -2.55]
        case .left, .right:
            return [self == .left ? -3.66:3.66, 0.06+(Self.roofHeight(uv.x)-0.06)*uv.y, -0.35-2.2*uv.x]
        case .roof: return [-3.66+7.32*uv.x, Self.roofHeight(uv.y), -0.35-2.2*uv.y]
        }
    }
    func coordinates(_ p: SIMD3<Float>) -> SIMD2<Float> {
        let depth=(-p.z-0.35)/2.2
        switch self {
        case .back: return [(p.x+3.66)/7.32,(p.y-0.06)/2.29]
        case .left, .right: return [depth,(p.y-0.06)/(Self.roofHeight(depth)-0.06)]
        case .roof: return [(p.x+3.66)/7.32,depth]
        }
    }
    func normal(_ uv: SIMD2<Float>) -> SIMD3<Float> {
        switch self {
        case .back: return [0,0,-1]
        case .left: return [-1,0,0]
        case .right: return [1,0,0]
        case .roof: return simd_normalize([0,1,-(0.09+0.09 * .pi*cos(.pi*uv.y))/2.2])
        }
    }
    func distance(_ p: SIMD3<Float>) -> Float {
        let uv=coordinates(p)
        return simd_dot(p-point(uv),normal(uv))
    }
    func contains(_ uv: SIMD2<Float>) -> Bool { uv.x>=0 && uv.x<=1 && uv.y>=0 && uv.y<=1 }
    func edgeWeight(_ uv: SIMD2<Float>) -> Float {
        let size: SIMD2<Float> = self == .back ? [7.32,2.29] : self == .roof ? [7.32,2.2]:[2.2,2.3]
        let d=simd_min(uv,1-uv)*size
        return smooth(d.x/0.42)*smooth(d.y/0.42)
    }
    private static func roofHeight(_ u: Float) -> Float { 2.44-0.09*u-0.09*sin(.pi*u) }
}

nonisolated struct NetImpact {
    let panel: NetPanel
    let start: Double
    let direction: Float
    let strength: Float
    var center: SIMD2<Float>
    var depth: Float = 0
    var peak: Float = 0
    var released: Double?

    func displacement(at uv: SIMD2<Float>, time: Double) -> Float {
        let age=Float(time-start)
        guard age>=0 else { return 0 }
        let distance=simd_distance(panel.point(uv),panel.point(center))
        let pin=panel.edgeWeight(uv)
        let envelope=min(1.3,pin/max(0.12,panel.edgeWeight(center)))
        let width: Float=0.43+peak*0.45
        var bulge=depth
        if let released {
            let t=max(0,Float(time-released))
            bulge=peak*0.14*sin(t*17)*exp(-t*6)
        }
        let ripple=0.045*strength*exp(-age*3.2)*sin(distance*12-age*20)
            * exp(-pow((distance-age*2.4)/0.6,2))
        return direction * (bulge*exp(-distance*distance/(width*width))*envelope+ripple*pin)
    }
}

/// Deterministic post-contact flight. A damped spring lets the ball stretch a local
/// net pocket before releasing it. This is a bounded net approximation, not cloth FEM.
nonisolated struct GoalBallPhysics {
    static let radius: Float=0.11
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var impacts=[NetImpact]()
    var woodworkTime: Double?
    private var active=[NetPanel:Int]()

    init(position: SIMD3<Float>, velocity: SIMD3<Float>) {
        self.position=position;self.velocity=velocity
    }
    mutating func step(time: Double, dt: Float) {
        let h=dt/4
        for substep in 0..<4 {
            let now=time-Double(dt)+Double(substep+1)*Double(h)
            let previous=position
            velocity.y -= 9.81*h
            velocity *= exp(-0.012*simd_length(velocity)*h)
            position += velocity*h
            if let hit=Self.frameHit(from:previous,to:position),simd_dot(velocity,hit.normal)<0 {
                position=hit.point+hit.normal*0.001
                velocity=Self.rebound(velocity,normal:hit.normal,restitution:0.62,friction:0.08)
                woodworkTime=now
            }
            for panel in NetPanel.allCases {
                let projected=panel.coordinates(position)
                let uv=simd_clamp(projected,SIMD2<Float>(repeating:0),SIMD2<Float>(repeating:1))
                // Include the sphere's overlap at seams. Testing only its centre
                // leaves a gap when a stretched side pocket reaches the back edge.
                let inside=simd_distance(panel.point(projected),panel.point(uv))<=Self.radius
                let d=panel.distance(position),before=panel.distance(previous)
                let normal=panel.normal(uv)
                if active[panel] == nil && inside {
                    let toward=simd_dot(velocity,normal)
                    let crossed=(before < -Self.radius && d >= -Self.radius) || (before > Self.radius && d <= Self.radius)
                    let approaching=abs(d)<=Self.radius && before*toward<0
                    if crossed || approaching {
                        let direction: Float = before<0 ? 1:-1
                        active[panel]=impacts.count
                        impacts.append(NetImpact(panel:panel,start:now,direction:direction,strength:clamp(abs(toward)/12,0.1,1.5),center:uv))
                    }
                }
                guard let index=active[panel] else { continue }
                let direction=impacts[index].direction
                let depth=d*direction+Self.radius
                if !inside || depth<0 {
                    impacts[index].depth=0;impacts[index].released=now;active[panel]=nil
                    continue
                }
                impacts[index].center=uv;impacts[index].depth=depth
                impacts[index].peak=max(impacts[index].peak,depth)
                let outward=normal*direction, speed=simd_dot(velocity,outward)
                let stiffness: Float=260+260*(1-panel.edgeWeight(uv))
                // Unilateral contact: the net may push the ball back, never pull it.
                let force=max(0,stiffness*depth+(speed>0 ? 24:65)*speed)
                velocity -= outward*force*h
                let tangent=velocity-outward*simd_dot(velocity,outward)
                velocity -= tangent*min(0.06,depth*12*h)
            }
            // Turf, the advertising board and the stepped terrace behind the goal.
            let ground=Self.groundHeight(at:position)
            if position.y<Self.radius+ground {
                position.y=Self.radius+ground
                if velocity.y < -0.8 { velocity.y = -velocity.y*0.43;velocity.x *= 0.82;velocity.z *= 0.82 }
                else { velocity.y=0 }
                let horizontal=SIMD2(velocity.x,velocity.z),speed=simd_length(horizontal)
                let scale=max(0,1-1.5*h/max(0.001,speed))
                velocity.x *= scale;velocity.z *= scale
            }
            if abs(position.x)<24 && position.y<1.01 && previous.z > -6.74 && position.z <= -6.74 {
                position.z = -6.74;velocity.z=abs(velocity.z)*0.42;velocity.x *= 0.8
            }
        }
    }
    var resting: Bool { simd_length(velocity)<0.03 }
    static func groundHeight(at p: SIMD3<Float>) -> Float {
        guard abs(p.x)<22,p.z < -8.61,p.z > -16.14 else { return 0 }
        return min(10,floor((-p.z-8.61)/0.75)+1)*0.4
    }
    static func rebound(_ v: SIMD3<Float>, normal: SIMD3<Float>, restitution: Float, friction: Float) -> SIMD3<Float> {
        let n=normal*simd_dot(v,normal)
        return (v-n)*(1-friction)-n*restitution
    }
    struct FrameHit { let point: SIMD3<Float>;let normal: SIMD3<Float>;let fraction: Float }
    /// Swept sphere against the cylindrical posts/crossbar, including their end caps.
    static func frameHit(from a: SIMD3<Float>,to b: SIMD3<Float>) -> FrameHit? {
        var best: FrameHit?
        for (start,end): (SIMD3<Float>,SIMD3<Float>) in [
            ([-3.72,0,-0.35],[-3.72,2.5,-0.35]),([3.72,0,-0.35],[3.72,2.5,-0.35]),
            ([-3.72,2.5,-0.35],[3.72,2.5,-0.35])] {
            let axis=simd_normalize(end-start),length=simd_length(end-start),delta=b-a,q=a-start
            let d=delta-axis*simd_dot(delta,axis),r=q-axis*simd_dot(q,axis)
            let aa=simd_dot(d,d),bb=2*simd_dot(r,d),cc=simd_dot(r,r)-0.17*0.17
            var candidates=[Float]()
            if aa>0.0000001,bb*bb-4*aa*cc>=0 { candidates.append((-bb-sqrt(bb*bb-4*aa*cc))/(2*aa)) }
            for t in candidates where t>=0 && t<=1 {
                let p=a+delta*t,along=simd_dot(p-start,axis)
                if along>=0 && along<=length {
                    let hit=FrameHit(point:p,normal:simd_normalize(p-(start+axis*along)),fraction:t)
                    if best == nil || t<best!.fraction { best=hit }
                }
            }
            for cap in [start,end] {
                let c=a-cap,aa=simd_dot(delta,delta),bb=2*simd_dot(c,delta),cc=simd_dot(c,c)-0.17*0.17
                guard aa>0.0000001,bb*bb-4*aa*cc>=0 else { continue }
                let t=(-bb-sqrt(bb*bb-4*aa*cc))/(2*aa)
                if t>=0 && t<=1 && (best == nil || t<best!.fraction) {
                    let p=a+delta*t;best=FrameHit(point:p,normal:simd_normalize(p-cap),fraction:t)
                }
            }
        }
        return best
    }
}

#endif
