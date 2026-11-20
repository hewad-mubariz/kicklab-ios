#if DEBUG
import Foundation

/// Shared steady-ball evidence for wall games and goal setup. Coordinates and
/// diameter must use the same units on both axes (pixels or image-width units).
nonisolated struct WallBallHold: Sendable {
    struct Sample: Sendable {
        let t, x, y, d, score, aspect: Double
        var usable: Bool {
            [t,x,y,d,score,aspect].allSatisfy(\.isFinite)
                && d>0 && score>=0.45 && (0.65...1.55).contains(aspect)
        }
    }
    struct Update: Sendable { let progress: Double; let diameter: Double? }
    let duration: Double
    let minimumSamples: Int
    // Goal setup credits only consecutive measured frames, capped per frame.
    // Wall games retain their existing elapsed-time and sample-count policy.
    var maximumFrameCredit: Double? = nil
    private var samples: [Sample] = []
    private var lastAccepted: Double?
    private var lastObservation = -Double.infinity
    private var previousAccepted = false
    private var visibleDuration = 0.0
    private(set) var progress = 0.0

    init(duration: Double, minimumSamples: Int, maximumFrameCredit: Double? = nil) {
        self.duration=duration;self.minimumSamples=minimumSamples;self.maximumFrameCredit=maximumFrameCredit
    }

    mutating func add(_ sample: Sample?, now: Double) -> Update {
        guard now.isFinite, now>lastObservation else { return .init(progress:progress,diameter:nil) }
        lastObservation=now
        if let lastAccepted, now-lastAccepted>0.5 {
            samples=[];self.lastAccepted=nil;visibleDuration=0;progress=0;previousAccepted=false
        }
        let wasAccepted=previousAccepted
        previousAccepted=false
        guard let s=sample,s.usable,abs(s.t-now)<0.01,
              samples.last.map({s.t>$0.t}) ?? true else { return .init(progress:progress,diameter:nil) }
        if !samples.isEmpty {
            let d=Self.median(samples.map(\.d)),x=Self.median(samples.map(\.x)),y=Self.median(samples.map(\.y))
            // Ignore one bad box; sustained movement expires through the gap.
            guard abs(s.d/d-1)<=0.25,hypot(s.x-x,s.y-y)<=d*0.6 else {
                return .init(progress:progress,diameter:nil)
            }
        }
        if let maximumFrameCredit,let lastAccepted,wasAccepted {
            visibleDuration += min(maximumFrameCredit,now-lastAccepted)
        }
        samples.append(s);lastAccepted=now;previousAccepted=true
        if samples.count>240 { samples.removeFirst(samples.count-240) }
        let elapsed=maximumFrameCredit == nil ? s.t-samples[0].t:visibleDuration
        progress=min(0.99,max(0,elapsed/duration))
        let median=Self.median(samples.map(\.d))
        let mad=Self.median(samples.map {abs($0.d-median)})
        guard elapsed>=duration,samples.count>=minimumSamples,mad/median<0.10 else {
            return .init(progress:progress,diameter:nil)
        }
        progress=1
        return .init(progress:1,diameter:median)
    }
    private static func median(_ values: [Double]) -> Double {values.sorted()[values.count/2]}
}
#endif
