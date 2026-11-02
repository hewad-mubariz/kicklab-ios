// Copied from the Effects Lab (Water, accepted 1 November 2026); only isolation is added for the app.
import Foundation
import simd

/// Reorganizes the same number of fluid particles and initial burst energy into
/// a rolling lip and thin radial streams. The lip uses neighbour pressure;
/// sparse streams retain differential velocities. No rigid splash mesh is used.
nonisolated enum WaterCrown {
    static let rimCount=72*8
    private static let lock=NSLock()
    nonisolated(unsafe) private static var cache:[Int:[[WaterFlow.Atom]]]=[:]
    nonisolated(unsafe) private static var preparing=false
    static let variants=12

    private static func bake(_ key:Int)->[[WaterFlow.Atom]] {
        var atoms=initial(seed:key),frames=[atoms]
        for stepIndex in 1...Int(ceil(WaterFlow.lifetime/WaterFlow.dt)) {
            step(&atoms)
            if stepIndex%3==0 {frames.append(atoms)}
        }
        return frames
    }

    /// Every variation, solved now outside the lock. An export calls this first so each frame is complete.
    static func prepareAll() {
        for key in 0..<variants {
            lock.lock();let done=cache[key] != nil;lock.unlock()
            guard !done else {continue}
            let frames=bake(key)
            lock.lock();if cache[key]==nil {cache[key]=frames};lock.unlock()
        }
    }

    static func prepareInBackground() {
        lock.lock()
        let start = !preparing && cache.count<variants
        preparing=preparing || start
        lock.unlock()
        guard start else {return}
        Task.detached(priority:.utility) {prepareAll()}
    }

    /// The release's particles at `age`, or nil while its variation is still being solved; drawing
    /// never runs the solver.
    static func readySample(age:Float,seed:Int)->[WaterFlow.Atom]? {
        let key=((seed%variants)+variants)%variants
        lock.lock();let ready=cache[key] != nil;lock.unlock()
        guard ready else {prepareInBackground();return nil}
        return sample(age:age,seed:seed)
    }
    static func initial(seed:Int)->[WaterFlow.Atom] {
        let phase=Float(seed)*1.17
        var atoms=[WaterFlow.Atom]()
        for column in 0..<72 {for ring in 0..<8 {
            let u=Float(column)/71,phi=Float(ring)*2*Float.pi/8
            let theta:Float=1.98+u*3.12+0.10*sin(phase)
            let n=SIMD3<Float>(cos(theta),sin(theta),0),t=SIMD3<Float>(-n.y,n.x,0)
            let bulge:Float=0.16+0.045*sin(u*13+phase)+0.018*sin(u*39-phase)
            let radius:Float=1.25+0.035*sin(u*18+phase)
            var p=n*(radius+bulge*cos(phi))
            p.z=bulge*sin(phi)+0.35*sin(u*6+phase)
            let key=Float(atoms.count+seed*1733)
            p+=SIMD3(WaterScene.hash(key)-0.5,WaterScene.hash(key+2)-0.5,WaterScene.hash(key+7)-0.5)*0.012
            let surge:Float=5.5+1.7*sin(u*14+phase)+0.8*sin(u*31-phase)
            // Circulation across the lip gives the front/back water unequal
            // trajectories. Surface tension/pressure act on this moving fluid.
            var v=n*(surge-bulge*sin(phi)*24)+t*(1.8+sin(u*8+phase))
            v.z=bulge*cos(phi)*24+1.2*sin(u*7+phase);v.y-=1.2
            atoms.append(WaterFlow.Atom(p:p,v:v,id:atoms.count))
        }}
        for stream in 0..<18 {for step in 0..<60 {
            let key=Float(stream+seed*31),u=(Float(stream)+0.22+0.55*WaterScene.hash(key))/18
            let v=Float(step)/59,theta:Float=2.0+u*3.10+0.14*sin(v*5+key)
            let n=SIMD3<Float>(cos(theta),sin(theta),0),t=SIMD3<Float>(-n.y,n.x,0)
            var p=n*(0.68+v*(0.68+0.55*WaterScene.hash(key+11)))
            p.z=0.18*sin(u*6+phase)+0.08*sin(v*4+key)
            var velocity=n*(2.7+v*6.4+0.5*sin(v*17+key))+t*(1.2+v*1.5+0.8*sin(v*8+key))
            velocity.z=0.4+v*1.2+0.6*sin(key)+0.5*sin(v*9+key);velocity.y-=1.2
            atoms.append(WaterFlow.Atom(p:p,v:velocity,id:atoms.count))
        }}
        // Match the liked burst's mean velocity and velocity variance. Count
        // and particle mass are equal, so initial momentum and energy match.
        let baseline=WaterFlow.initial(seed:seed)
        func mean(_ values:[WaterFlow.Atom])->SIMD3<Float> {values.map(\.v).reduce(.zero,+)/Float(values.count)}
        let oldMean=mean(baseline),newMean=mean(atoms)
        let target=baseline.map{simd_length_squared($0.v-oldMean)}.reduce(0,+)
        let actual=atoms.map{simd_length_squared($0.v-newMean)}.reduce(0,+)
        let scale=sqrt(target/max(0.00001,actual))
        for i in atoms.indices {atoms[i].v=oldMean+(atoms[i].v-newMean)*scale}
        return atoms
    }
    static func step(_ atoms:inout [WaterFlow.Atom]) {
        var rim=Array(atoms.prefix(rimCount)),streams=Array(atoms.dropFirst(rimCount))
        WaterFlow.step(&rim,restDensity:6.0,nearStiffness:60,minPressure:-65)
        // A coarse pressure kernel gathers thin jets into blobs. Their
        // unequal velocities stretch and separate the transported particles.
        WaterFlow.step(&streams,interactions:false)
        atoms=rim+streams
    }
    static func sample(age:Float,seed:Int)->[WaterFlow.Atom] {
        let key=((seed%12)+12)%12
        lock.lock()
        if cache[key]==nil {
            var atoms=initial(seed:key),frames=[atoms]
            for stepIndex in 1...Int(ceil(WaterFlow.lifetime/WaterFlow.dt)) {
                step(&atoms)
                if stepIndex%3==0 {frames.append(atoms)}
            }
            cache[key]=frames
        }
        let frames=cache[key]!;lock.unlock()
        let t=max(0,min(Float(frames.count-1),age*60)),a=Int(t),b=min(a+1,frames.count-1),f=t-Float(a)
        return zip(frames[a],frames[b]).map{WaterFlow.Atom(p:simd_mix($0.p,$1.p,SIMD3(repeating:f)),v:simd_mix($0.v,$1.v,SIMD3(repeating:f)),id:$0.id,neighbours:$0.neighbours+($1.neighbours-$0.neighbours)*f)}
    }
}
