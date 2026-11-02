// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app.
import Foundation
import simd

/// Clavet-style double-density relaxation without springs. The pressure solve
/// is 2D; advected depth supplies folds. Gravity is applied in world space
/// by WaterScene, so small and large parcels fall at the same acceleration.
nonisolated enum WaterFluid {
    struct Atom { var p, v: SIMD3<Float>; var dye, volume: Float; var covariance = SIMD3<Float>(1,0,1); var neighbors: Float = 0 }
    struct Snapshot { var atoms: [Atom] }
    static let dt: Float = 1 / 120
    static let lifetime: Float = 1.02
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: [Snapshot]] = [:]
    private static func hash(_ x: Float) -> Float { WaterScene.hash(x) }
    private struct Cell: Hashable { var x, y: Int }
    private struct Pair { var a, b: Int; var q: Float; var n: SIMD2<Float> }

    static func initial(seed: Int, drop: Bool = false) -> [Atom] {
        var atoms = [Atom]()
        let phase = Float(seed) * 0.73
        // A curved parcel at birth, never an animated or ball-locked outline.
        // Tangential shear, pressure and gravity freely deform it after release.
        for row in 0..<13 { for column in 0..<90 {
            let u=Float(column)/89, w=Float(row)/12
            let id=Float(column+row*90+seed*2003)
            let theta=1.85+u*3.3+0.07*sin(phase)
            let ripple:Float=0.045*sin(u*31+phase)+0.022*sin(u*69-phase)
            let finger:Float=0.16*pow(max(0,sin(u*52+phase)),4)*w*w*w
            let radial:Float=1.08+ripple+w*(0.48+0.10*sin(u*13+phase))+finger
            let n=SIMD2(cos(theta),sin(theta)), tangent=SIMD2(-n.y,n.x)
            var p=n*radial+SIMD2(-0.15,-0.27)
            p+=SIMD2(hash(id)-0.5,hash(id+17)-0.5)*0.018
            let surge:Float=1.1+1.9*w+0.7*sin(u*16+phase)
            var v=n*surge+tangent*(1.2+2.4*w)
            v+=SIMD2(-0.65,-1.2)+n*(sin(u*37+phase)*w*w*0.8)
            var z:Float=0.32*sin(theta*1.3+phase*0.2)+0.20*sin(w*4.6+u*7)+0.12*sin(u*36+w*17+phase)+0.035*sin(u*67-w*29)
            var vz:Float=sin(u*5+phase)*0.6+(w-0.5)*1.4
            if drop {
                let q=SIMD2((u-0.5)*1.15,(w-0.5)*0.65)
                let side:Float=column<45 ? -1:1
                p=q+SIMD2(side*0.65,0);v=SIMD2(-side*3.6,side*0.4)
                z=0.15*sin(u*8);vz=0
            }
            atoms.append(Atom(p:SIMD3(p.x,p.y,z),v:SIMD3(v.x,v.y,vz),
                dye:u,volume:0.85+hash(id+3)*0.25))
        }}
        return atoms
    }
    static func step(_ atoms: inout [Atom], gravity: Float = 0, interactions: Bool = true) {
        let count = atoms.count, h: Float = 0.18
        let old = atoms.map(\.p)
        for i in atoms.indices {
            atoms[i].v.y += gravity * dt
            atoms[i].v *= 1 - 0.12 * dt
            atoms[i].p += atoms[i].v * dt
        }
        guard interactions else { return }
        var cells = [Cell: [Int]]()
        for i in atoms.indices {
            let p = atoms[i].p
            cells[Cell(x:Int(floor(p.x/h)),y:Int(floor(p.y/h))),default:[]].append(i)
        }
        var pairs = [Pair](); pairs.reserveCapacity(count*12)
        var density = [Float](repeating:0,count:count), near = density
        for i in atoms.indices {
            let p=atoms[i].p,cx=Int(floor(p.x/h)),cy=Int(floor(p.y/h))
            for y in (cy-1)...(cy+1) { for x in (cx-1)...(cx+1) {
                guard let indices=cells[Cell(x:x,y:y)] else {continue}
                for j in indices where j>i {
                    let d=SIMD2(atoms[j].p.x-p.x,atoms[j].p.y-p.y),r=simd_length(d)
                    guard r<h,r>0.00001 else {continue}
                    let q=1-r/h
                    pairs.append(Pair(a:i,b:j,q:q,n:d/r))
                    density[i]+=q*q;density[j]+=q*q;near[i]+=q*q*q;near[j]+=q*q*q
                }
            }}
        }
        let pressure=density.map{max(-55,min(180,42*($0-4.2)))}
        var displacement=[SIMD2<Float>](repeating:.zero,count:count)
        var viscosity=[SIMD3<Float>](repeating:.zero,count:count)
        for pair in pairs {
            let i=pair.a,j=pair.b,q=pair.q
            let d=pair.n*(dt*dt*0.5*((pressure[i]+pressure[j])*q+80*(near[i]+near[j])*q*q))
            displacement[i]-=d;displacement[j]+=d
            let dv=(atoms[j].v-atoms[i].v)*(0.003*q)
            viscosity[i]+=dv;viscosity[j]-=dv
            let dz=(atoms[j].p.z-atoms[i].p.z)*(0.003*q)
            atoms[i].p.z+=dz;atoms[j].p.z-=dz
        }
        for i in atoms.indices {
            let d=displacement[i],length=simd_length(d)
            let bounded=d*min(1,0.018/max(0.00001,length))
            atoms[i].p.x+=bounded.x;atoms[i].p.y+=bounded.y
            atoms[i].v=(atoms[i].p-old[i])/dt+viscosity[i]
        }
    }
    private static func reconstruct(_ input:[Atom])->[Atom] {
        var atoms=input,cells=[Cell:[Int]]()
        let h:Float=0.34
        for i in atoms.indices {
            cells[Cell(x:Int(floor(atoms[i].p.x/h)),y:Int(floor(atoms[i].p.y/h))),default:[]].append(i)
        }
        for i in atoms.indices {
            let p=atoms[i].p,cx=Int(floor(p.x/h)),cy=Int(floor(p.y/h))
            var xx:Float=0.0008,xy:Float=0,yy:Float=0.0008,count=0
            for y in (cy-1)...(cy+1) {for x in (cx-1)...(cx+1) {
                for j in cells[Cell(x:x,y:y)] ?? [] where i != j {
                    let d=SIMD2(atoms[j].p.x-p.x,atoms[j].p.y-p.y),r2=simd_length_squared(d)
                    if r2<h*h {
                        let w=1-r2/(h*h)
                        xx+=d.x*d.x*w;xy+=d.x*d.y*w;yy+=d.y*d.y*w;count+=1
                    }
                }
            }}
            atoms[i].neighbors=Float(count)
            atoms[i].covariance=count>=2 ? SIMD3(xx,xy,yy):SIMD3(1,0,1)
        }
        return atoms
    }
    static func bake(seed:Int,drop:Bool=false)->[Snapshot] {
        var atoms=initial(seed:seed,drop:drop),result=[Snapshot(atoms:reconstruct(atoms))]
        for i in 1...Int(ceil(lifetime/dt)) {
            step(&atoms,gravity:0)
            if i%2==0 {result.append(Snapshot(atoms:reconstruct(atoms)))}
        }
        return result
    }
    static func sample(age:Float,seed:Int,drop:Bool=false)->[Atom] {
        // Cache twelve numerical variations, never rendered images. Arbitrary
        // seeking and paused frames reproduce the same fixed-step simulation.
        let variant=((seed%12)+12)%12,key=variant+(drop ? 100:0)
        lock.lock()
        if cache[key]==nil {cache[key]=bake(seed:variant,drop:drop)}
        let frames=cache[key]!
        lock.unlock()
        let t=max(0,min(Float(frames.count-1),age*60)),a=Int(t),b=min(a+1,frames.count-1),f=t-Float(a)
        return zip(frames[a].atoms,frames[b].atoms).map{first,second in
            Atom(p:simd_mix(first.p,second.p,SIMD3(repeating:f)),v:simd_mix(first.v,second.v,SIMD3(repeating:f)),dye:first.dye,volume:first.volume,covariance:simd_mix(first.covariance,second.covariance,SIMD3(repeating:f)),neighbors:first.neighbors+(second.neighbors-first.neighbors)*f)
        }
    }
}
