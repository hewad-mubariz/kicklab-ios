import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Current-frame boundary and learned appearance must agree before a proposed
/// ball region can contribute foreground. Predictions only seed the search.
nonisolated final class BallCutoutTracker {
    private var last:(bounds:CGRect,time:Double,velocity:SIMD2<Double>)?
    private var appearance:BallImageLocator.Appearance?
    private var radii:[Double]=[]
    private var previousTime:Double?
    private(set) var quality=0.0

    func update(source:CVPixelBuffer,hint:CGRect?,confidence:Double,at time:Double) throws -> CGRect? {
        if let previousTime,time<=previousTime || time-previousTime>0.15 {last=nil;appearance=nil;radii=[]}
        previousTime=time;quality=0
        let detected=hint.flatMap {confidence>=0.05 && DetailedForegroundMaskProcessor.visibleBallCrop($0) != nil ? $0:nil}
        var proposals:[CGRect]=detected.map {[$0]} ?? []
        let prior=last.flatMap {time-$0.time<=0.35 ? $0:nil}
        if let prior {
            let dt=time-prior.time
            proposals.append(prior.bounds.offsetBy(dx:prior.velocity.x*dt,dy:prior.velocity.y*dt))
            proposals.append(prior.bounds)
        }
        guard !proposals.isEmpty else {return nil}
        let sorted=radii.sorted(),radius=sorted.isEmpty ? nil:sorted[sorted.count/2]
        guard let match=BallImageLocator.locate(source,proposals:proposals,appearance:appearance,expectedRadius:radius) else {return nil}
        let b=match.bounds,dt=prior.map {max(0.001,time-$0.time)} ?? 1
        var velocity=prior.map {SIMD2(Double(b.midX-$0.bounds.midX),Double(b.midY-$0.bounds.midY))/dt} ?? .zero
        let speed=SIMD2(Double(b.width),Double(b.height))*3/dt
        velocity=simd_clamp(velocity,-speed,speed)
        last=(b,time,velocity);quality=match.quality
        if appearance == nil {appearance=match.appearance}
        else if match.quality>22 && match.support>0.7 {
            appearance!.color=appearance!.color*0.95+match.appearance.color*0.05
            appearance!.chroma=appearance!.chroma*0.95+match.appearance.chroma*0.05
        }
        radii.append(Double(b.width)*Double(CVPixelBufferGetWidth(source))/2)
        if radii.count>12 {radii.removeFirst()}
        return b
    }

}
