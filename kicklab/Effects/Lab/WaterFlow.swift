// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app.
import Foundation
import simd

/// Three-dimensional double-density relaxation. Compact fluid is released with
/// varying outward/shear velocity; there is no rest-shape or crescent mesh.
/// Pressure and mild cohesion act between current neighbours, not stored edges.
nonisolated enum WaterFlow {
    struct Atom {var p,v:SIMD3<Float>;var id:Int;var neighbours:Float=0}
    private struct Cell:Hashable {var x,y,z:Int}
    private struct Pair {var a,b:Int;var q:Float;var n:SIMD3<Float>}
    static let dt:Float=1/180, lifetime:Float=0.85
    private static let lock=NSLock()
    nonisolated(unsafe) private static var cache:[Int:[[Atom]]]=[:]
    static func initial(seed:Int)->[Atom] {
        var atoms=[Atom]();let phase=Float(seed)*1.17
        for depth in 0..<3 {for row in 0..<6 {for column in 0..<92 {
            let u=Float(column)/91,w=Float(row)/5,k=Float(atoms.count+seed*2311)
            let angle:Float=1.85+u*3.10+0.16*sin(phase)
            let n=SIMD3<Float>(cos(angle),sin(angle),0),t=SIMD3<Float>(-n.y,n.x,0)
            let radial:Float=1.02+w*0.22+0.015*sin(u*31+phase)
            var p=n*radial
            p.z=Float(depth-1)*0.065+0.13*sin(u*8+phase)+0.025*sin(u*41)
            p+=SIMD3(WaterScene.hash(k)-0.5,WaterScene.hash(k+5)-0.5,WaterScene.hash(k+8)-0.5)*0.018
            // Fast unequal jets open a crown from a compact film. The outer
            // layer overtakes the inner layer, rather than carrying a fixed rim.
            let outward:Float=4.0+5.0*w+2.0*sin(u*21+phase)+1.2*sin(u*47)
            var v=n*outward+t*(1.5+2.0*w+1.8*sin(u*9+phase))
            v.z = -1.6+3.8*w+2.4*sin(u*12+phase)
            v.y -= 1.2
            atoms.append(Atom(p:p,v:v,id:atoms.count))
        }}}
        return atoms
    }
    static func step(_ atoms:inout [Atom],interactions:Bool=true,restDensity:Float=5.5,nearStiffness:Float=72,minPressure:Float = -34) {
        let h:Float=0.21,old=atoms.map(\.p)
        for i in atoms.indices {atoms[i].v *= 1-0.10*dt;atoms[i].p += atoms[i].v*dt}
        guard interactions else{return}
        var cells=[Cell:[Int]]()
        func cell(_ p:SIMD3<Float>)->Cell {Cell(x:Int(floor(p.x/h)),y:Int(floor(p.y/h)),z:Int(floor(p.z/h)))}
        for i in atoms.indices {cells[cell(atoms[i].p),default:[]].append(i)}
        var pairs=[Pair](),density=[Float](repeating:0,count:atoms.count),near=density
        var neighbours=density
        for i in atoms.indices {
            let c=cell(atoms[i].p)
            for z in (c.z-1)...(c.z+1) {for y in (c.y-1)...(c.y+1) {for x in (c.x-1)...(c.x+1) {
                for j in cells[Cell(x:x,y:y,z:z)] ?? [] where j>i {
                    let delta=atoms[j].p-atoms[i].p,d=simd_length(delta)
                    if d>0.00001 && d<h {
                        let q=1-d/h;pairs.append(Pair(a:i,b:j,q:q,n:delta/d))
                        density[i]+=q*q;density[j]+=q*q;near[i]+=q*q*q;near[j]+=q*q*q
                        neighbours[i]+=1;neighbours[j]+=1
                    }
                }
            }}}
        }
        let pressure=density.map{max(minPressure,min(180,45*($0-restDensity)))}
        var shift=[SIMD3<Float>](repeating:.zero,count:atoms.count),viscosity=shift
        for pair in pairs {
            let i=pair.a,j=pair.b,q=pair.q
            let correction=pair.n*(dt*dt*0.5*((pressure[i]+pressure[j])*q+nearStiffness*(near[i]+near[j])*q*q))
            shift[i]-=correction;shift[j]+=correction
            let dv=(atoms[j].v-atoms[i].v)*(0.0018*q)
            viscosity[i]+=dv;viscosity[j]-=dv
        }
        for i in atoms.indices {
            let d=shift[i];atoms[i].p+=d*min(1,0.012/max(0.000001,simd_length(d)))
            atoms[i].v=(atoms[i].p-old[i])/dt+viscosity[i]
            atoms[i].neighbours=neighbours[i]
        }
    }
    static func sample(age:Float,seed:Int)->[Atom] {
        let key=((seed%12)+12)%12
        lock.lock()
        if cache[key]==nil {
            var atoms=initial(seed:key),frames=[atoms]
            for stepIndex in 1...Int(ceil(lifetime/dt)) {
                step(&atoms)
                if stepIndex%3==0 {frames.append(atoms)}
            }
            cache[key]=frames
        }
        let frames=cache[key]!;lock.unlock()
        let t=max(0,min(Float(frames.count-1),age*60)),a=Int(t),b=min(a+1,frames.count-1),f=t-Float(a)
        return zip(frames[a],frames[b]).map{Atom(p:simd_mix($0.p,$1.p,SIMD3(repeating:f)),v:simd_mix($0.v,$1.v,SIMD3(repeating:f)),id:$0.id,neighbours:$0.neighbours+($1.neighbours-$0.neighbours)*f)}
    }
}
