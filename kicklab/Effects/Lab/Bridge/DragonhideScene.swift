// Copied from the Effects Lab (EffectLab/DragonhideScene.swift), 2026-11-19; only isolation is added for the app.
import Foundation
import simd

nonisolated enum DragonhideSkin:Int {case dragonhide=0}
nonisolated enum DragonhideScene {
    static func uniforms(skin:DragonhideSkin,time:Float,size:SIMD2<Float>,ball:SIMD4<Float>,pose:simd_quatf,source:Bool,relief:Float=1,blend:Float=1)->GoldUniforms {
        var frame=GoldScene.uniforms(time:time,size:size,ball:ball,pose:pose,source:source,roughness:0.29,relief:relief,blend:blend)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
    static func preview(skin:DragonhideSkin,time:Float,size:SIMD2<Float>,moving:Bool,relief:Float=1)->GoldUniforms {
        var frame=GoldScene.preview(time:time,size:size,moving:moving,roughness:0.29,relief:relief)
        frame.options.w=Float(skin.rawValue)
        return frame
    }
}

nonisolated struct DragonhideVertex {
    var position:SIMD4<Float>
    var normal:SIMD4<Float>
    var detail:SIMD4<Float>
}

/// Every scale is an independent curved plate with a rolled rim and side wall.
/// The geometry is generated once and rotates with the recorded source pose.
nonisolated enum DragonhideMesh {
    static func make()->([DragonhideVertex],[UInt32],Int) {
        var vertices=[DragonhideVertex](),indices=[UInt32](),scaleCount=0
        let pi=Float.pi
        func add(_ p:SIMD3<Float>,_ detail:SIMD4<Float>)->UInt32 {
            vertices.append(DragonhideVertex(position:SIMD4(p.x,p.y,p.z,1),normal:.zero,detail:detail));return UInt32(vertices.count-1)
        }
        func tri(_ a:UInt32,_ b:UInt32,_ c:UInt32){indices.append(contentsOf:[a,b,c])}
        func direction(_ theta:Float,_ phi:Float)->SIMD3<Float>{SIMD3(sin(theta)*sin(phi),cos(theta),sin(theta)*cos(phi))}
        // A dark supporting sphere prevents holes between independently layered scales.
        let stacks=40,slices=80,base=vertices.count
        for row in 0...stacks {for column in 0...slices {
            let n=direction(pi*Float(row)/Float(stacks),2*pi*Float(column)/Float(slices))
            _=add(n*0.939,SIMD4(0,0,0,-1))
        }}
        for row in 0..<stacks {for column in 0..<slices {
            let a=UInt32(base+row*(slices+1)+column),b=a+1,c=a+UInt32(slices+1),d=c+1
            tri(a,c,b);tri(b,c,d)
        }}
        let rings:[Float]=[0.12,0.26,0.42,0.58,0.72,0.83,0.89,0.93,0.955,0.975,0.99,1.0]
        let segments=48,rows=8
        for row in 0..<rows {
            let theta=pi*(Float(row)+0.5)/Float(rows)
            let columns=max(3,Int((10*sin(theta)).rounded()))
            let width=min(0.46,pi*sin(theta)/Float(columns)*1.27)
            let height=pi/Float(rows)*1.04
            for column in 0..<columns {
                let id=Float(scaleCount);scaleCount+=1
                let shift=row%2==0 ? Float(0):0.5
                let seed=sin(id*12.9898)*43758.5453,variation=seed-floor(seed)
                let jitter=sin(id*7.31+4)
                let slender:Float=variation<0.34 ? 1:0
                let widthVariation:Float=0.89+variation*0.15-slender*0.05
                let heightVariation:Float=0.99+slender*0.12+sin(id*4.81)*0.045
                let roundness:Float=slender>0 ? 0.58+variation*0.12:0.76+variation*0.12
                let phi=2*pi*(Float(column)+shift+jitter*0.085)/Float(columns)
                let localTheta=theta+sin(id*3.77)*0.024
                let axis=direction(localTheta,phi),east=SIMD3<Float>(cos(phi),0,-sin(phi)),down=SIMD3<Float>(cos(localTheta)*sin(phi),-sin(localTheta),cos(localTheta)*cos(phi))
                func point(_ radial:Float,_ angle:Float,_ wall:Bool=false)->(SIMD3<Float>,SIMD4<Float>){
                    let asymmetry:Float=1+0.075*sin(id*4.13)*sin(angle)
                    let y = (cos(angle)>=0 ? -cos(angle):(-cos(angle)*roundness+pow(max(0,1-abs(sin(angle))),0.75)*(1-roundness)))*radial
                    let taper:Float=1-(0.04+slender*0.12)*max(0,-cos(angle))
                    let x=sin(angle)*(0.94+0.06*cos(angle))*radial*asymmetry*taper+jitter*0.09*pow(max(0,y),2)
                    let roll=jitter*0.18
                    let xx=x*cos(roll)-y*sin(roll),yy=x*sin(roll)+y*cos(roll)
                    let n=simd_normalize(axis+east*tan(xx*width*widthVariation)+down*tan(yy*height*heightVariation))
                    // A lifted free end sits above the next plate's attached shoulder.
                    // The recessed core must not clip away the upper half of each scale.
                    let dome:Float=0.014*(1-radial*radial)
                    let lift:Float=0.068*(y+1)*0.5
                    let bead:Float=0.0065*exp(-pow((radial-0.963)/0.040,2))
                    let radius:Float=(0.962+dome+lift+bead+(variation-0.5)*0.002-(wall ? 0.022:0))*0.979
                    return (n*radius,SIMD4(x,y,wall ? 1.06:radial,id))
                }
                let center=point(0,0);let centerIndex=add(center.0,center.1)
                var loops=[[UInt32]]()
                for t in rings {
                    var loop=[UInt32]()
                    for i in 0..<segments {let p=point(t,2*pi*Float(i)/Float(segments));loop.append(add(p.0,p.1))}
                    loops.append(loop)
                }
                for i in 0..<segments {tri(centerIndex,loops[0][i],loops[0][(i+1)%segments])}
                for j in 1..<loops.count {for i in 0..<segments {
                    let k=(i+1)%segments,a=loops[j-1][i],b=loops[j-1][k],c=loops[j][i],d=loops[j][k]
                    tri(a,c,b);tri(b,c,d)
                }}
                // Explicit thick underside, separate from the bright bead at the lip.
                var wall=[UInt32]()
                for i in 0..<segments {let p=point(1,2*pi*Float(i)/Float(segments),true);wall.append(add(p.0,p.1))}
                let rim=loops.last!
                for i in 0..<segments {let k=(i+1)%segments;tri(rim[i],wall[i],rim[k]);tri(rim[k],wall[i],wall[k])}
            }
        }
        // Accumulate smooth normals within each plate; do not weld across plates.
        var sums=[SIMD3<Float>](repeating:.zero,count:vertices.count)
        for i in stride(from:0,to:indices.count,by:3) {
            let a=Int(indices[i]),b=Int(indices[i+1]),c=Int(indices[i+2])
            let p=vertices[a].position,q=vertices[b].position,r=vertices[c].position
            let pa=SIMD3(p.x,p.y,p.z),pb=SIMD3(q.x,q.y,q.z),pc=SIMD3(r.x,r.y,r.z)
            var n=simd_cross(pb-pa,pc-pa)
            if simd_dot(n,pa+pb+pc)<0 {n = -n}
            sums[a]+=n;sums[b]+=n;sums[c]+=n
        }
        for i in vertices.indices {
            let p=vertices[i].position
            let fallback=simd_normalize(SIMD3(p.x,p.y,p.z))
            let n=simd_length_squared(sums[i])>1e-12 ? simd_normalize(sums[i]):fallback
            vertices[i].normal=SIMD4(n.x,n.y,n.z,0)
        }
        return (vertices,indices,scaleCount)
    }
}
