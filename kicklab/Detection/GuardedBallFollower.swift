import Foundation
import CoreGraphics

/// Detector-only evidence. Coordinates use a 1920-long-edge upright image,
/// matching the desktop policy; masks remain normalized to the real source.
nonisolated struct FollowHit {
    var rect: CGRect
    var score: Double
    var mask: BallMask? = nil
    var diameter: Double { max(rect.width, rect.height) }
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

nonisolated struct FollowView: Hashable {
    let x: Int, y: Int, width: Int, height: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Causal port of the desktop detector guards and three-frame crop recovery.
/// Pixel evidence is supplied separately by the native tracker. Pending states
/// never emit a box or change the committed detector trajectory.
nonisolated final class GuardedBallFollower {
    struct Output {
        var hit: FollowHit?
        var kind = "lost"
        var calls = 0
    }
    private struct Pending {
        var hit: FollowHit
        var time: Double
        var started: Double
        var velocity = CGPoint.zero
        var frames: Int
        var strongest: Double
    }
    private(set) var last: FollowHit?
    private(set) var verified = -Double.infinity
    private var observed = -Double.infinity, fullTime = -Double.infinity
    private var cropTime = -Double.infinity, recoveryTime = -Double.infinity
    private var restartTime = -Double.infinity, cropRestartTime = -Double.infinity
    private var previousTime = -Double.infinity
    private var velocity = CGPoint.zero
    private var acquired = false, ever = false
    private var seed: FollowHit?, seeds = 0
    private var pending: Pending?, cropPending: Pending?
    private var dimensions = CGSize.zero

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
    static func moved(_ p: CGPoint, _ v: CGPoint, _ dt: Double) -> CGPoint {
        CGPoint(x: p.x + v.x*dt, y: p.y + v.y*dt)
    }
    static func agrees(_ a: FollowHit, _ b: FollowHit) -> Bool {
        distance(a.center,b.center) <= 0.3*a.diameter && (0.5...2).contains(b.diameter/a.diameter)
    }
    static func square(_ center: CGPoint, _ side: Double, _ size: CGSize) -> FollowView {
        let s = Int(min(size.width,size.height,max(1,side.rounded(.toNearestOrEven))))
        return FollowView(x: Int(max(0,min(size.width-Double(s),center.x-Double(s)/2)).rounded(.toNearestOrEven)),
            y: Int(max(0,min(size.height-Double(s),center.y-Double(s)/2)).rounded(.toNearestOrEven)), width:s,height:s)
    }
    static func edge(_ hit: FollowHit, _ view: FollowView, _ size: CGSize) -> Bool {
        (view.x > 0 && hit.rect.minX-view.rect.minX <= 2) ||
        (view.y > 0 && hit.rect.minY-view.rect.minY <= 2) ||
        (view.rect.maxX < size.width && view.rect.maxX-hit.rect.maxX <= 2) ||
        (view.rect.maxY < size.height && view.rect.maxY-hit.rect.maxY <= 2)
    }
    private func commit(_ hit: FollowHit, _ time: Double, _ motion: CGPoint) {
        last=hit; observed=time; verified=time; velocity=motion
        acquired=true; ever=true; seed=nil; seeds=0; pending=nil; cropPending=nil
    }
    func reset() {
        last=nil; verified = -.infinity; observed = -.infinity; fullTime = -.infinity
        cropTime = -.infinity; recoveryTime = -.infinity; restartTime = -.infinity
        cropRestartTime = -.infinity; previousTime = -.infinity
        acquired=false; ever=false; seed=nil; seeds=0; pending=nil; cropPending=nil; velocity = .zero
    }
    enum Failure: Error { case timestamp }

    func step(time t: Double, size: CGSize, flow: FollowHit?, sceneCut: Bool,
              infer: (FollowView) throws -> [FollowHit]) throws -> Output {
        guard t.isFinite, t > previousTime else { throw Failure.timestamp }
        if dimensions != size || sceneCut { reset(); dimensions=size }
        previousTime=t
        let full=FollowView(x:0,y:0,width:Int(size.width),height:Int(size.height))
        let previous=last, stale=ever && t-verified >= 0.15
        var expected: CGPoint?
        var cache: [FollowView: [FollowHit]] = [:], order: [FollowView] = []
        var acceptedCalls: [(FollowView,[FollowHit])] = []
        func valid(_ d: FollowHit) -> Bool {
            [d.rect.minX,d.rect.minY,d.rect.maxX,d.rect.maxY,d.score].allSatisfy(\.isFinite)
                && d.rect.minX >= 0 && d.rect.minY >= 0 && d.rect.maxX <= size.width
                && d.rect.maxY <= size.height && min(d.rect.width,d.rect.height) >= 3
        }
        func raw(_ view: FollowView) throws -> [FollowHit] {
            if let hits=cache[view] { return hits }
            let hits=try infer(view); cache[view]=hits; order.append(view); return hits
        }
        func support(_ d: FollowHit, _ view: FollowView, strong: Bool) throws -> Bool {
            let expanded = view == full
                ? Self.square(d.center,max(480,16*d.diameter),size)
                : Self.square(CGPoint(x:view.rect.midX,y:view.rect.midY),Double(max(view.width,view.height))*1.5,size)
            guard expanded != view else { return false }
            return try raw(expanded).contains { other in
                valid(other) && other.score >= 0.3 && !Self.edge(other,expanded,size)
                    && Self.agrees(d,other) && (!strong || max(other.score,d.score) >= 0.6)
            }
        }
        func screened(_ view: FollowView) throws -> [FollowHit] {
            var kept: [FollowHit] = []
            for d in try raw(view) where valid(d) && d.score >= 0.3 {
                if stale, let previous {
                    let local = acquired && expected != nil && t-verified <= 0.35
                        && (2.0/3...1.5).contains(d.diameter/previous.diameter)
                        && Self.distance(d.center,expected!) <= max(12,previous.diameter)
                        && !Self.edge(d,view,size)
                    if local, try support(d,view,strong:false) { kept.append(d) }
                    continue
                }
                var suspicious = false
                if let previous, let expected {
                    suspicious = d.score < 0.6 && (!(2.0/3...1.5).contains(d.diameter/previous.diameter)
                        || Self.distance(d.center,expected) > previous.diameter)
                }
                if Self.edge(d,view,size) || suspicious {
                    if try !support(d,view,strong:suspicious) { continue }
                }
                kept.append(d)
            }
            acceptedCalls.append((view,kept)); return kept
        }
        func region() -> FollowView {
            let p=expected ?? Self.moved(last!.center,velocity,t-observed)
            let side=max(240,last!.diameter*8,hypot(velocity.x,velocity.y)*(t-observed)*4)
            return Self.square(p,side,size)
        }
        var output=Output()
        if !acquired {
            let hits=try screened(full); fullTime=t
            if let chosen=hits.filter({$0.score >= 0.6}).max(by:{$0.score < $1.score}) {
                let consistent=seed.map { Self.distance(chosen.center,$0.center) <= max(20,chosen.diameter*1.5) } ?? false
                seeds=consistent ? seeds+1 : 1; seed=chosen
                if seeds >= 3 { commit(chosen,t,.zero); output.hit=chosen; output.kind="detector_acquisition" }
            } else { seeds=0; seed=nil }
        } else if let last {
            let age=t-verified
            if age > 0.35 { acquired=false; seeds=0 }
            else {
                var tracked=flow
                if let f=tracked {
                    let motion=Self.moved(last.center,velocity,t-observed)
                    if !valid(f) || Self.distance(f.center,motion) > max(3,last.diameter*0.5) { tracked=nil }
                }
                expected=tracked?.center ?? Self.moved(last.center,velocity,t-observed)
                let view=region(), maximum=max(30,last.diameter*2.5,hypot(velocity.x,velocity.y)*(t-observed)*2)
                func compatible(_ d: FollowHit) -> Bool {
                    valid(d) && d.score >= 0.3 && (0.2...2).contains(d.diameter/last.diameter)
                }
                func plausible(_ d: FollowHit) -> Bool { compatible(d) && Self.distance(d.center,expected!) <= maximum }
                var candidates: [FollowHit] = []
                if tracked == nil || age >= 0.15 || t-cropTime >= 0.05-1e-6 {
                    candidates += try screened(view); cropTime=t
                }
                if t-fullTime >= 0.25-1e-6 { candidates += try screened(full); fullTime=t }
                var choices=candidates.filter(plausible), directionChange=false
                if choices.isEmpty && t-recoveryTime >= 0.05 && age >= 0.05-1e-6 && last.diameter <= 0.04*max(size.width,size.height) {
                    recoveryTime=t
                    var views: [[FollowHit]] = []
                    for side in [max(96,4*last.diameter),Double(view.width)*2/3,Double(view.width)*4/3] {
                        let extra=Self.square(expected!,max(4*last.diameter,side),size)
                        if !acceptedCalls.contains(where:{$0.0 == extra}) { views.append(try screened(extra).filter(plausible)) }
                    }
                    for (i,viewHits) in views.enumerated() { for d in viewHits {
                        let corroborated=views.enumerated().contains { j,others in j != i && others.contains { Self.agrees(d,$0) } }
                        if d.score >= 0.6 || corroborated { choices.append(d) }
                    } }
                    if choices.isEmpty && tracked == nil && age >= 0.1 {
                        let locals=acceptedCalls.filter{$0.0 != full}.map { $0.1.filter { compatible($0)
                            && view.rect.contains($0.center) } }
                        for (i,hits) in locals.enumerated() { for d in hits {
                            if locals.enumerated().contains(where: { j,others in j != i && others.contains {
                                Self.agrees(d,$0) && max(d.score,$0.score) >= 0.6
                            } }) { choices.append(d) }
                        } }
                        directionChange = !choices.isEmpty
                    }
                }
                if let chosen=choices.min(by: { Self.distance($0.center,expected!)/maximum-0.15*$0.score
                    < Self.distance($1.center,expected!)/maximum-0.15*$1.score }) {
                    let dt=t-observed
                    let measured=CGPoint(x:(chosen.center.x-last.center.x)/dt,y:(chosen.center.y-last.center.y)/dt)
                    let v=directionChange ? measured : CGPoint(x:0.5*(velocity.x+measured.x),y:0.5*(velocity.y+measured.y))
                    commit(chosen,t,v); output.hit=chosen; output.kind="detector_verified"
                } else if var f=tracked, age <= 0.15 {
                    f.mask=nil; output.hit=f; output.kind="pixel_track"
                }
            }
        }
        if output.hit != nil { pending=nil; cropPending=nil }
        else if stale && !sceneCut {
            if cropPending != nil { restartTime = -.infinity }
            if pending != nil || t-restartTime >= 0.05-1e-6 {
                restartTime=t
                var proposals: [FollowHit] = []
                for d in try raw(full) where d.score >= 0.6 && valid(d) {
                    if try support(d,full,strong:true) { proposals.append(d) }
                }
                var consistent: [FollowHit] = []
                if let p=pending, t-p.time > 0, t-p.time <= 0.1 {
                    let allowance=max(2*p.hit.diameter,hypot(size.width,size.height)*1.5*(t-p.time))
                    consistent=proposals.filter { Self.distance($0.center,p.hit.center) <= allowance
                        && (0.5...2).contains($0.diameter/p.hit.diameter) }
                }
                if let chosen=(consistent.isEmpty ? proposals : consistent).max(by:{$0.score < $1.score}) {
                    let old=pending, count=consistent.isEmpty ? 1 : (pending!.frames+1)
                    pending=Pending(hit:chosen,time:t,started:t,frames:count,strongest:chosen.score)
                    if count >= 3, let old {
                        let v=CGPoint(x:(chosen.center.x-old.hit.center.x)/(t-old.time),y:(chosen.center.y-old.hit.center.y)/(t-old.time))
                        commit(chosen,t,v); output.hit=chosen; output.kind="detector_reacquisition"
                    }
                } else { pending=nil }
            }
        }
        if output.hit == nil && pending == nil && !sceneCut && ever, let last,
           t-verified >= 0.15, t-verified <= 0.5, last.diameter <= 0.04*max(size.width,size.height) {
            if let p=cropPending, t-p.time > 0.1 || t-p.started > 0.12 { cropPending=nil }
            if cropPending != nil || t-cropRestartTime >= 0.05-1e-6 {
                cropRestartTime=t
                func usable(_ d: FollowHit, _ view: FollowView) -> Bool {
                    view != full && d.score >= 0.3 && valid(d) && !Self.edge(d,view,size)
                }
                func contexts(_ p: CGPoint, _ diameter: Double) -> [FollowView] {
                    let a=Self.square(p,max(240,12*diameter),size), b=Self.square(p,max(240,12*diameter)*1.5,size)
                    return a == b ? [a] : [a,b]
                }
                var candidates: [(FollowHit,Double)] = []
                var pendingExpected=CGPoint.zero
                if let p=cropPending {
                    let dt=t-p.time
                    pendingExpected=Self.moved(p.hit.center,p.velocity,dt)
                    let views=contexts(pendingExpected,p.hit.diameter)
                    for view in views { _=try raw(view) }
                    for (i,view) in views.enumerated() { for d in try raw(view) where usable(d,view) {
                        let allowance=p.frames >= 2 ? max(4,p.hit.diameter*0.75) : max(p.hit.diameter*2,hypot(size.width,size.height)*1.5*dt)
                        guard Self.distance(d.center,pendingExpected) <= allowance,
                              (0.5...2).contains(d.diameter/p.hit.diameter) else { continue }
                        var supporters: [FollowHit] = []
                        for otherView in views.dropFirst(i+1) { supporters += try raw(otherView).filter { usable($0,otherView) && Self.agrees(d,$0) } }
                        if !supporters.isEmpty { candidates.append((d,max(d.score,supporters.map(\.score).max()!))) }
                    } }
                } else {
                    if !order.contains(where:{$0 != full}) { _=try raw(region()) }
                    var seeds: [FollowHit] = []
                    for view in order { for d in cache[view]! {
                        if usable(d,view) && (0.5...2).contains(d.diameter/last.diameter) && !seeds.contains(where:{Self.agrees(d,$0)}) { seeds.append(d) }
                    } }
                    for seed in seeds.sorted(by:{$0.score > $1.score}).prefix(3) {
                        var supporting: [FollowHit] = []
                        for view in contexts(seed.center,seed.diameter) {
                            if let d=try raw(view).filter({usable($0,view) && Self.agrees(seed,$0)}).max(by:{$0.score < $1.score}) { supporting.append(d) }
                        }
                        if supporting.count >= 2 && Self.agrees(supporting[0],supporting[1]) {
                            let strongest=supporting.max(by:{$0.score < $1.score})!
                            candidates.append((strongest,max(seed.score,strongest.score)))
                        }
                    }
                }
                if !candidates.isEmpty {
                    let old=cropPending
                    let chosen=old == nil ? candidates.max(by:{$0.1 < $1.1})! : candidates.min(by:{Self.distance($0.0.center,pendingExpected) < Self.distance($1.0.center,pendingExpected)})!
                    let v=old.map { CGPoint(x:(chosen.0.center.x-$0.hit.center.x)/(t-$0.time),y:(chosen.0.center.y-$0.hit.center.y)/(t-$0.time)) } ?? .zero
                    let count=(old?.frames ?? 0)+1, strength=max(old?.strongest ?? 0,chosen.1)
                    cropPending=Pending(hit:chosen.0,time:t,started:old?.started ?? t,velocity:v,frames:count,strongest:strength)
                    if count >= 3 && strength >= 0.6 {
                        commit(chosen.0,t,v); output.hit=chosen.0; output.kind="crop_reacquisition"
                    }
                } else { cropPending=nil }
            }
        } else { cropPending=nil }
        output.calls=order.count
        return output
    }
}
