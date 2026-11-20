#if DEBUG
import Foundation

/// Fits vertical image coordinate * relative depth, where a free ball follows
/// a parabola. Short tracks use a gravity prior instead of extrapolating a chip
/// upwards forever. Longer tracks can correct that prior from measurements.
nonisolated enum PhysicalBallArc {
    struct Fit {
        let value, slope, curvature: Double
        func at(_ time: Double) -> Double { value+slope*time+curvature*time*time }
    }
    static func gravityPrior(wallDiameter: Double, imageAspect: Double,
                             ballDiameterMeters: Double=0.22) -> Double {
        // f / wallDistance comes from the wall-ball size. This trial assumes
        // the same nominal 22 cm football used by the scene.
        0.5*9.81*wallDiameter*imageAspect/ballDiameterMeters
    }
    static func fit(_ t: [Double],_ v: [Double],gravityPrior: Double) -> Fit {
        let linear=line(t,v)
        let squares=t.map { $0*$0 },base=line(t,squares)
        let residual=zip(t,squares).map { $1-base.value-base.slope*$0 }
        let denominator=residual.reduce(0) { $0+$1*$1 }
        // About 0.004 of normalized perspective coordinate as observation
        // noise. A short, noisy track cannot overturn gravity with three points.
        let regularization=0.004*0.004
        let c=max(0,min(4,(zip(residual,v).reduce(0) { $0+$1.0*$1.1 }
            + regularization*gravityPrior)/(denominator+regularization)))
        return Fit(value:linear.value-c*base.value,slope:linear.slope-c*base.slope,curvature:c)
    }
    private static func line(_ t: [Double],_ v: [Double]) -> (value: Double,slope: Double) {
        let n=Double(t.count),mt=t.reduce(0,+)/n,mv=v.reduce(0,+)/n
        let variance=t.reduce(0) { $0+pow($1-mt,2) }
        let slope=zip(t,v).reduce(0) { $0+($1.0-mt)*($1.1-mv) }/max(1e-9,variance)
        return (mv-slope*mt,slope)
    }
}
#endif
