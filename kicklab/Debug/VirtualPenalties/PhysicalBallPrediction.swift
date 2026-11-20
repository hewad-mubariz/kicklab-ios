#if DEBUG
import Foundation
import simd

/// Camera centres are normalised to image width/height; diameter to width.
nonisolated struct PhysicalBallSample: Sendable {
    var time: Double
    var x, y, diameter, confidence, aspect: Double
    var held = false
    var imageAspect = 16.0/9.0
    var released = false
    var usable: Bool {
        [time,x,y,diameter,confidence,aspect].allSatisfy(\.isFinite)
        && (0...1).contains(x) && (0...1).contains(y)
        && (0.005...0.5).contains(diameter) && confidence >= 0.55
        && (0.65...1.5).contains(aspect)
    }
    var hasUnclippedBounds: Bool {
        // diameter averages box width and height in camera-width units.
        // Leave 10% of a radius clear of the frame: an edge-clipped ball has
        // a biased size, which can turn an early high shot into a low forecast.
        let rx=diameter*aspect/(1+aspect)*1.1
        let ry=diameter*imageAspect/(1+aspect)*1.1
        return imageAspect.isFinite && imageAspect>0 &&
            x>rx && x<1-rx && y>ry && y<1-ry
    }
}

nonisolated struct PhysicalBallPrediction: Sendable {
    let observedAt, arrival, remaining: Double
    let image: SIMD2<Double>
    let samples: Int
}

/// Fits perspective-correct camera coordinates using apparent ball size as a
/// relative depth measurement. No assumed kick time, virtual flight, or hit
/// event is used. The wall diameter must be measured explicitly during setup.
nonisolated struct PhysicalBallPredictor {
    var wallDiameter: Double
    var verticalGravity: Double?
    private let rejectClippedBounds: Bool
    private let earlyAnticipation: Bool
    private var history: [PhysicalBallSample] = []
    private var previous: PhysicalBallPrediction?
    private var earlyPrevious: PhysicalBallPrediction?
    private var lastTime = -Double.infinity
    private var cooldownUntil = -Double.infinity
    private var refineUntil = -Double.infinity
    private(set) var refinement: PhysicalBallPrediction?
    private(set) var preparation: PhysicalBallPrediction?
    private(set) var reason = "Waiting for an approaching ball"
    init(wallDiameter: Double, verticalGravity: Double?=nil, rejectClippedBounds: Bool=true,
         earlyAnticipation: Bool=true) {
        self.wallDiameter=wallDiameter;self.verticalGravity=verticalGravity
        self.rejectClippedBounds=rejectClippedBounds
        self.earlyAnticipation=earlyAnticipation
    }
    mutating func waitForRecovery(until time: Double) { cooldownUntil=max(cooldownUntil,time) }
    mutating func commit(_ prediction: PhysicalBallPrediction) {
        cooldownUntil=prediction.arrival+1.8
        refineUntil=prediction.arrival+0.18
        reason="Committed to the approaching ball"
    }

    mutating func reset() {
        history=[];previous=nil;earlyPrevious=nil;lastTime = -.infinity;cooldownUntil = -.infinity
        refineUntil = -.infinity;refinement=nil;preparation=nil
        reason="Waiting for an approaching ball"
    }

    mutating func consume(_ sample: PhysicalBallSample?, at time: Double,
                          automaticallyCommit: Bool=true) -> PhysicalBallPrediction? {
        guard time.isFinite,time > lastTime else { return nil }
        lastTime=time
        refinement=nil;preparation=nil
        let refining=time<cooldownUntil
        if refining,time>=refineUntil {
            history=[];previous=nil;earlyPrevious=nil;reason="Recovering · rebound ignored";return nil
        }
        guard wallDiameter.isFinite,wallDiameter > 0 else { reason="Measure the ball at the wall";return nil }
        if let last=history.last,time-last.time>0.18 { history=[];previous=nil;earlyPrevious=nil }
        guard let sample,sample.usable,(!rejectClippedBounds || sample.hasUnclippedBounds),
              !sample.held,abs(sample.time-time)<0.01 else {
            if sample?.held == true { history=[];previous=nil;earlyPrevious=nil;reason="Release the ball" }
            return nil
        }
        let depth=wallDiameter/sample.diameter
        guard (0.12...1.12).contains(depth) else { history=[];previous=nil;earlyPrevious=nil;return nil }
        history.append(sample)
        history.removeAll { time-$0.time>0.28 }
        guard history.count>=2,let first=history.first,time-first.time>=0.035 else {
            reason="Following the ball";return nil
        }
        let fullWindow=history.count>=3 && time-first.time>=0.075
        guard earlyAnticipation || fullWindow else { return nil }
        let times=history.map { $0.time-time }
        let depths=history.map { wallDiameter/$0.diameter }
        let z=Self.line(times,depths)
        let spread=depths.max()!-depths.min()!
        let minimumSpread=history.count==2 && earlyAnticipation ? 0.045:0.075
        guard z.slope>0.65,spread>minimumSpread,depths.last!>depths.first!+minimumSpread*0.8 else {
            previous=nil;earlyPrevious=nil;reason="Waiting for forward motion";return nil
        }
        let error=zip(times,depths).map { abs($0.1-(z.value+z.slope*$0.0)) }.max()!
        guard error<0.065 else { previous=nil;earlyPrevious=nil;reason="Uncertain ball size";return nil }
        let remaining=(1-z.value)/z.slope
        guard (0.035...0.75).contains(remaining) else { previous=nil;earlyPrevious=nil;reason="Waiting for a closer approach";return nil }
        let xx=zip(history,depths).map { $0.x*$1 }
        let yy=zip(history,depths).map { $0.y*$1 }
        let x=Self.line(times,xx)
        // The live gravity prior keeps short chip tracks from extrapolating
        // upward indefinitely. Nil retains the original fit for review.
        let y=verticalGravity.map { PhysicalBallArc.fit(times,yy,gravityPrior:$0).at(remaining) }
            ?? Self.vertical(times,yy,at:remaining)
        let target=SIMD2<Double>(x.value+x.slope*remaining,y)
        guard target.x.isFinite,target.y.isFinite,(-0.4...1.4).contains(target.x),
              (-0.5...1.6).contains(target.y) else { previous=nil;earlyPrevious=nil;return nil }
        let prediction=PhysicalBallPrediction(observedAt:time,arrival:time+remaining,
            remaining:remaining,image:target,samples:history.count)
        if !refining { preparation=prediction }
        // Two sightings can ready the hands and weight, but never launch a dive.
        // A third can commit only when every depth interval agrees and successive
        // forecasts agree more tightly than the regular, longer-window policy.
        let speeds: [Double]=(1..<history.count).map { i in
            let travelled=depths[i]-depths[i-1]
            let elapsed=history[i].time-history[i-1].time
            return travelled/elapsed
        }
        let earlyStable=earlyAnticipation && !refining && history.count>=3
            && time-first.time>=0.06 && error<0.02
            && sample.confidence>=0.85 && history.allSatisfy { $0.confidence>=0.75 }
            && speeds.min()!>0.65 && speeds.min()!>speeds.max()!*0.55
            && (earlyPrevious.map {
                abs($0.arrival-prediction.arrival)<0.06 && simd_distance($0.image,target)<0.06
            } ?? false)
        earlyPrevious=prediction
        let stable=fullWindow && (previous.map {
            abs($0.arrival-prediction.arrival)<0.12 && simd_distance($0.image,target)<0.10
        } ?? false)
        if fullWindow { previous=prediction }
        guard stable || earlyStable else { reason="Reading direction · preparing";return nil }
        if refining {
            refinement=prediction
            reason="Refining the reach"
            return nil
        }
        // One commitment per approach. Bounces and returned balls do not cause
        // a second dive while the captured motion is recovering.
        if automaticallyCommit { commit(prediction) }
        else { reason="Approach ready for keeper" }
        return prediction
    }

    private static func line(_ t: [Double],_ v: [Double]) -> (value: Double,slope: Double) {
        let n=Double(t.count),mt=t.reduce(0,+)/n,mv=v.reduce(0,+)/n
        let variance=t.reduce(0) { $0+pow($1-mt,2) }
        let slope=zip(t,v).reduce(0) { $0+($1.0-mt)*($1.1-mv) }/max(1e-9,variance)
        return (mv-slope*mt,slope)
    }
    private static func vertical(_ t: [Double],_ v: [Double],at future: Double) -> Double {
        let linear=line(t,v)
        guard t.count>=5,t.last!-t.first!>=0.15 else { return linear.value+linear.slope*future }
        // Remove the linear component of t²; regress on the orthogonal remainder.
        let squares=t.map { $0*$0 },base=line(t,squares)
        let residual=zip(t,squares).map { $1-base.value-base.slope*$0 }
        let denominator=residual.reduce(0) { $0+$1*$1 }
        let c=clamp(zip(residual,v).reduce(0) { $0+$1.0*$1.1 }/max(1e-10,denominator),-1.5,3.5)
        let a=linear.value-c*base.value,b=linear.slope-c*base.slope
        return a+b*future+c*future*future
    }
}

nonisolated struct PhysicalKeeperTelemetry: Sendable {
    var state: String
    var armed: Bool
    var reactions: Int
    var trackingReason: String
    var corners: [[Double]]
    var wallDiameter: Double?
    var lastReaction: [Double]?
    var instruction: String=""
    var setupTarget: Int?
    var setupProgress: Double=0
    var completedHolds: [Double]=[]
    var countdown: Int?
    var setupMarkerHidden=false
    var trackedBall=false
    var displayLead: Double=0
    var flightReason=""
    var flightStartedAt: Double?
    var virtualResult: String?
    var reviewStage: String=""
    var ballSkin: String="classic"
    var json: [String:Any] {
        ["state":state,"armed":armed,"reactions":reactions,"trackingReason":trackingReason,"goalCorners":corners,
         "wallDiameter":wallDiameter as Any? ?? NSNull(),
         "lastReaction":lastReaction as Any? ?? NSNull(),
         "instruction":instruction,"setupTarget":setupTarget as Any? ?? NSNull(),
         "setupProgress":setupProgress,"completedHolds":completedHolds,
         "countdown":countdown as Any? ?? NSNull(),"setupMarkerHidden":setupMarkerHidden,
         "trackedBall":trackedBall,"displayLead":displayLead,"flightReason":flightReason,
         "flightStartedAt":flightStartedAt as Any? ?? NSNull(),
         "virtualResult":virtualResult as Any? ?? NSNull(),"reviewStage":reviewStage,
         "predictionPolicy":"direction-first-three-observation-v4","virtualResults":"recorded-display-pose-coverage-v2",
         "ballSkin":ballSkin,
         "presentationPolicy":"live-save-only-v2",
         "calibrationMethod":"goal-corners-shared-wall-hold-v3"]
    }
}
#endif
