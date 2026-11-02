import Foundation
import simd

/// Liquid Spectrum's solver, copied from the Effects Lab (accepted 1 November 2026).
/// Clavet-style double-density relaxation without springs. The pressure solve
/// is 2D; advected depth supplies folds. No fixed outline or fixed topology.
nonisolated enum LiquidFluid {
    struct Atom { var p, v: SIMD3<Float>; var dye, volume: Float; var covariance = SIMD3<Float>(1,0,1) }
    struct Snapshot { var atoms: [Atom] }
    static let dt: Float = 1 / 120
    static let lifetime: Float = 0.92
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: [Snapshot]] = [:]
    private static func hash(_ x: Float) -> Float { LiquidScene.hash(x) }
    nonisolated(unsafe) private static var preparing = false

    /// The twelve variations a touch can use. Drawing never runs the solver: a variation that is
    /// not ready yet is prepared in the background and its fluid appears once it is.
    static let variants = 12

    /// Every variation, solved now. An export calls this first so each frame is complete. The
    /// solver runs outside the lock, so drawing never waits on it.
    static func prepareAll() {
        for variant in 0..<variants {
            lock.lock()
            let done = cache[variant] != nil
            lock.unlock()
            guard !done else { continue }
            let frames = bake(seed: variant)
            lock.lock()
            if cache[variant] == nil { cache[variant] = frames }
            lock.unlock()
        }
    }

    static func prepareInBackground() {
        lock.lock()
        let start = !preparing && cache.count < variants
        preparing = preparing || start
        lock.unlock()
        guard start else { return }
        Task.detached(priority: .utility) { prepareAll() }
    }

    /// The release's particles at `age`, or nil while its variation is still being solved.
    static func readySample(age: Float, seed: Int) -> [Atom]? {
        let variant = ((seed % variants) + variants) % variants
        lock.lock()
        let ready = cache[variant] != nil
        lock.unlock()
        guard ready else { prepareInBackground(); return nil }
        return sample(age: age, seed: seed)
    }
    private struct Cell: Hashable { var x, y: Int }
    private struct Pair { var a, b: Int; var q: Float; var n: SIMD2<Float> }

    static func initial(seed: Int, drop: Bool = false) -> [Atom] {
        var atoms = [Atom]()
        for y in -17...17 { for x in -15...15 {
            let id = Float((y + 17) * 31 + x + 15 + seed * 997)
            let q = SIMD2<Float>(Float(x), Float(y)) * 0.055
            guard simd_length(q / SIMD2(0.80, 0.94)) < 1 else { continue }
            let noise = SIMD2(hash(id) - 0.5, hash(id + 1) - 0.5) * 0.038
            var p = q + noise + SIMD2<Float>(-0.85, 0.54)
            var v = SIMD2<Float>(-2.2 + q.x * 8.5, 0.5 + q.y * 7.0)
            // One initial nonuniform impulse. Subsequent deformation comes from
            // pressure, viscosity and gravity, not animated shape coordinates.
            v += SIMD2(-q.y, q.x) * (3.8 + sin(Float(seed)) * 1.2)
            v += SIMD2(sin(q.y * 7 + Float(seed)), cos(q.x * 8)) * 1.7
            v *= 0.72
            if drop {
                let side: Float = x < 0 ? -1 : 1
                p = SIMD2(side * 0.63 + q.x * 0.85, q.y * 0.85)
                v = SIMD2(-side * 3.6, side * 0.55)
            } else if simd_length(p) < 1.02 { continue }
            atoms.append(Atom(p: SIMD3(p.x,p.y,sin(q.y*4+Float(seed))*0.14+sin(q.x*7+q.y*5)*0.08),
                v: SIMD3(v.x,v.y,q.x*0.6), dye:max(0,min(1,(q.y+0.85)/1.7)), volume:0.55+hash(id+3)*0.9))
        }}
        return atoms
    }
    static func step(_ atoms: inout [Atom], gravity: Float = 8.5, interactions: Bool = true) {
        let count = atoms.count, h: Float = 0.18
        let old = atoms.map(\.p)
        for i in atoms.indices {
            atoms[i].v.y += gravity * dt
            atoms[i].v *= 1 - 0.17 * dt
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
            let dv=(atoms[j].v-atoms[i].v)*(0.006*q)
            viscosity[i]+=dv;viscosity[j]-=dv
            let dz=(atoms[j].p.z-atoms[i].p.z)*(0.006*q)
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
            atoms[i].covariance=count>=2 ? SIMD3(xx,xy,yy):SIMD3(1,0,1)
        }
        return atoms
    }
    static func bake(seed:Int,drop:Bool=false)->[Snapshot] {
        var atoms=initial(seed:seed,drop:drop),result=[Snapshot(atoms:reconstruct(atoms))]
        for i in 1...Int(ceil(lifetime/dt)) {
            step(&atoms,gravity:drop ? 0:8.5)
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
            Atom(p:simd_mix(first.p,second.p,SIMD3(repeating:f)),v:simd_mix(first.v,second.v,SIMD3(repeating:f)),dye:first.dye,volume:first.volume,covariance:simd_mix(first.covariance,second.covariance,SIMD3(repeating:f)))
        }
    }
}
