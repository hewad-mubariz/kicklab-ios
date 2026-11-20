#if DEBUG
import Foundation
import simd

/// The four blinking markers establish the goal's geometry. Only a central
/// ball hold is needed for wall-depth scale; edge holds added no mapping data.
nonisolated enum PhysicalCalibrationTarget {
    static let names=["Centre"]
    static let points: [SIMD2<Double>]=[[0.5,0.5]]
}

/// Progress comes from fresh, steady ball observations, never a UI timer.
nonisolated struct PhysicalCalibrationHold {
    let target: SIMD2<Double>
    let radius: Double
    let imageAspect: Double
    private var steady = WallBallHold(duration: duration, minimumSamples: 18, maximumFrameCredit: 0.10)
    private var measurementNotBefore = -Double.infinity
    private(set) var progress=0.0
    private(set) var message="Move the ball to the marked spot"
    static let duration=1.4
    init(target: SIMD2<Double>,radius: Double,imageAspect: Double) {
        self.target=target;self.radius=radius;self.imageAspect=imageAspect
    }
    func contains(_ sample: PhysicalBallSample) -> Bool {
        guard observation(sample).usable, (0...1).contains(sample.x), (0...1).contains(sample.y),
              (0.005...0.5).contains(sample.diameter), radius>0,imageAspect>0 else { return false }
        // The projected halo is 0.15 goal-width across; this gate is 0.119.
        // Its outer circle must never establish the real ball reference.
        return hypot(sample.x-target.x,(sample.y-target.y)/imageAspect)<=radius
            && sample.diameter<=radius*1.7
    }
    mutating func beginMeasurement(after time: Double) {
        steady = WallBallHold(duration: Self.duration, minimumSamples: 18, maximumFrameCredit: 0.10)
        progress=0;measurementNotBefore=time
        message="Hold still while the projected marker clears."
    }

    mutating func consume(_ sample: PhysicalBallSample?,at time: Double) -> Double? {
        // Wireless transport can still show the old centre cue briefly. Size
        // evidence starts only after it clears; the larger progress halo stays.
        guard time.isFinite,time>=measurementNotBefore else { return nil }
        let candidate=sample.flatMap { contains($0) ? observation($0):nil }
        let update=steady.add(candidate,now:time)
        progress=update.progress
        message=progress>0 ? "Hold still · keep the ball touching the wall"
            : "Place the ball inside the ring and keep it touching the wall"
        return update.diameter
    }

    private func observation(_ sample: PhysicalBallSample) -> WallBallHold.Sample {
        .init(t:sample.time,x:sample.x,y:sample.y/imageAspect,d:sample.diameter,
              score:sample.confidence,aspect:sample.aspect)
    }
}
#endif
