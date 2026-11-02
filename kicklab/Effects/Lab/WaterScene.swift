// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app.
import Foundation
import simd

nonisolated enum WaterStage:Int,CaseIterable,Identifiable {
    case drop,splash,motion
    var id:Int {rawValue}
    var title:String {["Drop","Splash","Motion"][rawValue]}
}
nonisolated struct WaterUniforms: Equatable, Sendable {var viewport,ball,options:SIMD4<Float>}
nonisolated struct WaterPart: Equatable, Sendable {
    var centerSize,shape,material:SIMD4<Float>
    var quadric0=SIMD4<Float>(1,0,0,1),quadric1=SIMD4<Float>(0,1,1,1)
}
nonisolated struct WaterFrame: Equatable, Sendable {var uniforms:WaterUniforms;var parts:[WaterPart];var surface:[WaterSurfaceVertex]=[]}

nonisolated enum WaterScene {
    private struct Release {
        var birth:Float
        var id,seed:Int
        var scale,lifetime:Float
        var side:Float
        var offset:SIMD2<Float>
    }
    static func hash(_ x:Float)->Float {let v=sin(x*127.1+311.7)*43758.5453;return v-floor(v)}
    static func smooth(_ a:Float,_ b:Float,_ x:Float)->Float {let t=max(0,min(1,(x-a)/(b-a)));return t*t*(3-2*t)}
    static func velocity(at t:Float,sample:(Float)->SIMD4<Float>)->SIMD2<Float> {
        let p=sample(t),q=sample(max(0,t-0.025))
        return simd_clamp((SIMD2(p.x,p.y)-SIMD2(q.x,q.y))/0.025,SIMD2(repeating:-p.z*24),SIMD2(repeating:p.z*24))
    }
    static func frame(time:Float,size:SIMD2<Float>,stage:WaterStage,intensity:Float,light:Bool,source:Bool,
                      touches:[Float],sample:(Float)->SIMD4<Float>)->WaterFrame {
        let ball=sample(time)
        var parts=[WaterPart]()
        let surface=[WaterSurfaceVertex]()
        var events=[Release]()
        if stage == .motion {
            for (i,t) in touches.enumerated() {
                let mainSide:Float=velocity(at:t+0.04,sample:sample).x>=0 ? 1:-1
                // A full touch release, followed by three smaller fresh flows at
                // the ball. Every release retains its own birth transform.
                let candidates=[
                    Release(birth:t+0.038,id:i*4,seed:i,scale:0.98,lifetime:0.58,side:mainSide,offset:SIMD2(-0.12*mainSide,0)),
                    Release(birth:t+0.125,id:i*4+1,seed:i+5,scale:0.46,lifetime:0.48,side:mainSide,offset:SIMD2(-0.48*mainSide,-0.10)),
                    Release(birth:t+0.20,id:i*4+2,seed:i+7,scale:0.32,lifetime:0.46,side:mainSide,offset:SIMD2(-0.60*mainSide,0.02)),
                    Release(birth:t+0.26,id:i*4+3,seed:i+9,scale:0.24,lifetime:0.46,side:-mainSide,offset:SIMD2(0.72*mainSide,0.15))
                ]
                events += candidates.filter{$0.birth<=time && time-$0.birth<$0.lifetime}
            }
            // Small fresh parcels maintain a wake between contacts. They use
            // their own birth sample, so none follows the current ball rigidly.
            let wakeInterval:Float=0.065,wakeLifetime:Float=0.38
            let lastTick=Int(floor(time/wakeInterval))
            let activeTicks=Int(ceil(wakeLifetime/wakeInterval))
            for tick in max(0,lastTick-activeTicks)...max(0,lastTick) {
                let birth=Float(tick)*wakeInterval,age=time-birth
                guard age>=0,age<0.38 else {continue}
                let speed=simd_length(velocity(at:birth,sample:sample))/max(1,sample(birth).z)
                guard speed>0.7 else {continue}
                let side:Float=tick%3==0 ? -1:1
                events.append(Release(birth:birth,id:1000+tick,seed:tick,scale:0.16,lifetime:0.38,side:side,offset:SIMD2(-side*0.87,-0.12)))
            }
        } else {
            // Follow one complete release, including deformation and breakup.
            let age=time.truncatingRemainder(dividingBy:1.5)
            events=age<WaterFluid.lifetime ? [Release(birth:time-age,id:3,seed:3,scale:1,lifetime:0.82,side:1,offset:.zero)]:[]
        }
        for event in events {
            let birth=event.birth,id=event.id
            let age=time-birth,b=sample(birth)
            guard b.w>0 else {continue}
            let drop=stage == .drop
            let radius=b.z*(drop ? 2.4:event.scale)
            let base=drop ? SIMD2(size.x*0.5,size.y*0.46):SIMD2(b.x,b.y)+event.offset*b.z
            let inherit:Float=event.scale<1 ? 0.82:0.95
            // The recorded free-flight acceleration is ~83 ball radii/s².
            // The preview bounce has a lower, ~20 R/s² acceleration. Apply
            // gravity in world units so scaling a parcel cannot make it float.
            let gravity:Float=drop ? 0:(source ? 83:20)
            let fall=SIMD2<Float>(0,0.5*gravity*b.z*age*age)
            let momentum:SIMD2<Float>=stage == .motion ? velocity(at:birth,sample:sample)*inherit*((1-exp(-age*0.55))/0.55):.zero
            let inherited=momentum+fall
            let fade=smooth(0,0.045,age)*(1-smooth(event.lifetime*0.75,event.lifetime,age))
            if !drop {
                guard let atoms=WaterCrown.readySample(age:age,seed:event.seed) else {continue}
                let kernels=WaterOptics.kernels(atoms)
                for (index,atom) in atoms.enumerated() {
                    // Radius shrinks only at the very end of each independent
                    // parcel. The connected body breaks through motion first.
                    let terminal=1-smooth(event.lifetime*0.80,event.lifetime,age)
                    // Thin jets narrow as their differential velocities stretch
                    // them. Small initial necks break earlier than the fat ends.
                    let jet=atom.id>=WaterCrown.rimCount
                    let neck:Float=jet ? 0.82+0.26*sin(Float(atom.id)*0.41+Float(event.seed)):1
                    let stretch:Float=jet ? sqrt(0.9/(0.9+6.4*age)):1
                    let radiusScale:Float=0.072*(0.67+0.33*smooth(1,12,atom.neighbours))*neck*stretch
                    let dropSize=radius*radiusScale*sqrt(max(0,terminal))
                    guard dropSize>0.25 else {continue}
                    let p=base+SIMD2(atom.p.x*event.side,atom.p.y)*radius+inherited
                    parts.append(WaterPart(centerSize:SIMD4(p.x,p.y,atom.p.z*radius,dropSize),
                        shape:SIMD4(kernels[index].shape.x,kernels[index].shape.y,kernels[index].shape.z*event.side,1),material:SIMD4(Float(atom.id%92)/91,Float(id*10000+atom.id),age,2),
                        quadric0:SIMD4(kernels[index].quadric0.x,kernels[index].quadric0.y*event.side,kernels[index].quadric0.z*event.side,kernels[index].quadric0.w),quadric1:kernels[index].quadric1))
                }
                // Fine spray has its own birth velocity and free trajectory.
                // It supplements the main interacting volume, never its outline.
                for j in 0..<95 {
                    let key=Float(j+event.seed*919),theta:Float=1.7+hash(key)*3.5
                    let n=SIMD2<Float>(cos(theta)*event.side,sin(theta))
                    let speed:Float=6+hash(key+7)*9
                    let p=base+n*radius*(1.05+speed*age)+inherited
                    let size:Float=j<7 ? 0.065+0.055*hash(key+2):j<27 ? 0.025+0.030*hash(key+2):0.008+0.014*hash(key+2)
                    let r=radius*size*sqrt(max(0,fade))
                    // Each drop streaks along its flight, faster drops longer, as spray does on video.
                    if r>0.28 {parts.append(WaterPart(centerSize:SIMD4(p.x,p.y,0.4*radius,r),
                        shape:SIMD4(1.2+speed*0.12,0.6,atan2(n.y,n.x),1),material:SIMD4(0,Float(id*10000+8000+j),age,1)))}
                }
                continue
            }
            let atoms=WaterFluid.sample(age:age,seed:event.seed,drop:true)
            for (j,atom) in atoms.enumerated() {
                if id>=1000 && j%2==1 {continue}
                let p=base+SIMD2(atom.p.x*event.side,atom.p.y)*radius+inherited
                // Neighborhood covariance aligns the surface kernel with the fluid's
                // local strand, rather than drawing a chain of round beads.
                let xx=atom.covariance.x,xy=atom.covariance.y*event.side,yy=atom.covariance.z
                let trace=xx+yy,disc=sqrt((xx-yy)*(xx-yy)+4*xy*xy)
                let ratio=(trace+disc)/max(0.0001,trace-disc)
                let stretch:Float=min(1.8,max(1,pow(ratio,0.23)))
                let angle=0.5*atan2(2*xy,xx-yy)
                let r=radius*0.078*(0.42+0.58*smooth(1,9,atom.neighbors))*sqrt(atom.volume)*sqrt(max(0,fade))
                guard r>0.25 else {continue}
                parts.append(WaterPart(centerSize:SIMD4(p.x,p.y,atom.p.z*radius,r),
                    shape:SIMD4(stretch,1/stretch,angle,1),
                    material:SIMD4(atom.dye,Float(id*10000+j),age,0)))
            }
        }
        return WaterFrame(uniforms:WaterUniforms(viewport:SIMD4(size.x,size.y,time,intensity),ball:ball,
            options:SIMD4(Float(stage.rawValue),light ? 1:0,source ? 1:0,Float(parts.count))),parts:parts,surface:surface)
    }
}
