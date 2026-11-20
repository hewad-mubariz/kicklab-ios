#if DEBUG
import Foundation
import simd

/// A short-lived picture of an observed incoming ball, never a launched shot.
/// Inverse apparent diameter gives relative depth; x*q and y*q remove
/// perspective before extrapolating. All times use the capture host clock.
nonisolated struct PhysicalBallFlight {
    struct Frame {
        let image: SIMD2<Double>
        let cameraDiameter: Double
        let opacity: Double
    }
    var wallDiameter: Double
    var verticalGravity: Double?
    private let rejectClippedBounds: Bool
    private var history: [PhysicalBallSample] = []
    private var lastTime = -Double.infinity
    private var blockedUntil = -Double.infinity
    private var track: Track?
    private(set) var approaches = 0
    private(set) var lastStartedAt: Double?
    private(set) var reason = "Waiting for your shot"
    private struct Track {
        let time, arrival, depth, depthSpeed, verticalCurve: Double
        let position, velocity: SIMD2<Double>
    }
    var arrival: Double? { track?.arrival }
    init(wallDiameter: Double, verticalGravity: Double?=nil, rejectClippedBounds: Bool=true) {
        self.wallDiameter=wallDiameter;self.verticalGravity=verticalGravity
        self.rejectClippedBounds=rejectClippedBounds
    }

    mutating func reset() {
        history=[];track=nil;lastTime = -.infinity;blockedUntil = -.infinity
        reason="Waiting for your shot"
    }

    mutating func consume(_ sample: PhysicalBallSample?, at time: Double) {
        guard time.isFinite,time>lastTime else { return }
        lastTime=time
        if let track,time>track.arrival+0.05 {
            blockedUntil=max(blockedUntil,track.arrival+0.65)
            self.track=nil;history=[]
        }
        guard time>=blockedUntil else { return }
        guard wallDiameter.isFinite,wallDiameter>0 else { reset();return }
        guard let sample,sample.usable,(!rejectClippedBounds || sample.hasUnclippedBounds),
              !sample.held,abs(sample.time-time)<0.01 else {
            if sample?.held == true {
                history=[];track=nil;reason="Release the ball"
            } else if time-(history.last?.time ?? -.infinity)>0.16 {
                history=[];track=nil;reason="Ball lost"
            }
            return
        }
        let q=wallDiameter/sample.diameter
        // The projected copy is at most half the measured wall-ball diameter.
        // It cannot seed or extend the physical flight, even if detected.
        guard (0.12...1.08).contains(q) else { return }
        if let last=history.last {
            if time-last.time>0.16 { history=[];track=nil }
            else if q < wallDiameter/last.diameter-0.045 {
                blockedUntil=time+0.45;history=[];track=nil;reason="Returning ball";return
            }
        }
        history.append(sample)
        history.removeAll { time-$0.time>0.20 }
        guard history.count>=2,let first=history.first,time-first.time>=0.04 else { return }
        let t=history.map { $0.time-time },depth=history.map { wallDiameter/$0.diameter }
        let z=Self.line(t,depth)
        guard z.slope>0.65,depth.last!>depth.first!+0.045 else {
            track=nil;reason="Waiting for forward motion";return
        }
        let error=zip(t,depth).map { abs($1-z.value-z.slope*$0) }.max()!
        guard error<0.055 else { track=nil;reason="Uncertain flight";return }
        let remaining=(1-z.value)/z.slope
        guard (0.015...0.85).contains(remaining) else { track=nil;return }
        let x=Self.line(t,zip(history,depth).map { $0.x*$1 })
        let yy=zip(history,depth).map { $0.y*$1 }
        let y=Self.line(t,yy)
        let arc=verticalGravity.map { PhysicalBallArc.fit(t,yy,gravityPrior:$0) }
        if track == nil { approaches += 1;lastStartedAt=time }
        track=Track(time:time,arrival:time+remaining,depth:z.value,depthSpeed:z.slope,
            verticalCurve:arc?.curvature ?? 0,
            position:[x.value,arc?.value ?? y.value],velocity:[x.slope,arc?.slope ?? y.slope])
        reason="Following your shot"
    }

    func frame(at now: Double, displayLead: Double) -> Frame? {
        guard let track,now.isFinite,displayLead.isFinite,
              now>=track.time,now-track.time<0.16 else { return nil }
        let future=now+max(0,min(0.25,displayLead))
        let dt=future-track.time
        guard dt<=0.40,future<track.arrival else { return nil }
        let q=track.depth+track.depthSpeed*dt
        guard (0.12...1.01).contains(q) else { return nil }
        let image=(track.position+track.velocity*dt+[0,track.verticalCurve*dt*dt])/q
        guard image.x.isFinite,image.y.isFinite,
              (-0.15...1.15).contains(image.x),(-0.15...1.15).contains(image.y) else { return nil }
        let freshness=min(1,(0.16-(now-track.time))/0.05)
        // Small, visibly virtual copy. Its entire silhouette remains below the
        // predictor's physical-ball size gate, including near the wall.
        return Frame(image:image,cameraDiameter:wallDiameter*(0.50-0.13*q),
                     opacity:max(0,freshness))
    }

    private static func line(_ t: [Double],_ v: [Double]) -> (value: Double,slope: Double) {
        let n=Double(t.count),mt=t.reduce(0,+)/n,mv=v.reduce(0,+)/n
        let variance=t.reduce(0) { $0+pow($1-mt,2) }
        let slope=zip(t,v).reduce(0) { $0+($1.0-mt)*($1.1-mv) }/max(1e-9,variance)
        return (mv-slope*mt,slope)
    }
}
#endif
