import AVFoundation
import Foundation
import simd

/// Streaming counterpart of the motion analysis body, gated by SharedBallPreparation. One serial
/// reader owns writes; the caller only reads after refine has returned. No pixels retained.
nonisolated final class SharedMotionAccumulator: @unchecked Sendable {
    let track: BallEffectTrack
    var timing = BallPreparationTiming(enabled: BallPreparationTiming.enabledForBuild)
    var entries = [BallSurfaceTimeline.Entry]()
    var pose = BallSurfaceTimeline.initial
    var previous: BallSurfaceMotion.Prepared?
    var previousTime: Double?
    var exposure: BallExposureCalibration
    var estimator: BallExposureEstimator
    var cpuSeconds = 0.0
    var reachedEOF = false
    init(track: BallEffectTrack, duration: Double, frameDuration: Double) {
        self.track = track
        exposure = BallExposureCalibration(duration: duration, frameDuration: frameDuration)
        estimator = BallExposureEstimator(frameDuration: frameDuration)
    }
    func consume(_ buffer: CMSampleBuffer) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { cpuSeconds += ProcessInfo.processInfo.systemUptime-started }
        timing.decodedFrames += 1
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
            autoreleasepool {
                guard time.isFinite,let pixels=CMSampleBufferGetImageBuffer(buffer),
                      let sample=timing.measure(.guide, { track.replacementGuide(at:time) }),sample.confidence>=0.3,
                      let fitted=timing.measure(.outline, { BallReplacementFootprint.fit(pixels:pixels,sample:sample) }),
                      let patch=timing.measure(.patch, { BallSurfaceMotion.patch(pixels:pixels,center:fitted.center,
                          radius:fitted.radii.reduce(0,+)/Double(fitted.radii.count)) }) else {
                    previous=nil;previousTime=nil
                    entries.append(BallSurfaceTimeline.Entry(time:time,orientation:pose,accepted:false,visible:false));return
                }
                let current = timing.measure(.pyramid, { BallSurfaceMotion.Prepared(patch) })
                timing.fittedFrames += 1
                var accepted=false
                timing.measure(.exposure) {
                    let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                    if let velocity = track.velocity(at: time, size: size) {
                        estimator.observe(time: time, velocity: velocity, patch: patch,
                                          radius: fitted.radii.reduce(0,+)/Double(fitted.radii.count))
                    }
                }
                if exposure.shouldMeasure(at: time) {
                    let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                    if let velocity = track.velocity(at: time, size: size),
                       let blur = timing.measure(.exposure, { BallReplacementMotionBlur.measured(pixels: pixels, body: fitted,
                            suggested: track.smear(at: time, size: size)) }) {
                        exposure.observe(time: time, smear: blur, velocity: velocity)
                    }
                }
                if let previous,let previousTime,time>previousTime,time-previousTime<0.06 {
                    timing.rotationPairs += 1
                    let result=timing.measure(.rotation, { BallSurfaceMotion.estimate(previous:previous,current:current) })
                    if result.accepted {
                        accepted=true
                        timing.acceptedPairs += 1
                        let vector=SIMD3<Float>(result.rotation),angle=simd_length(vector)
                        if angle>1e-7 {pose=simd_normalize(simd_quatf(angle:angle,axis:vector/angle)*pose)}
                    }
                }
                entries.append(BallSurfaceTimeline.Entry(time:time,orientation:pose,accepted:accepted,
                    white:timing.measure(.lighting, { BallSurfaceTimeline.white(pixels:pixels,center:fitted.center,
                        radius:fitted.radii.reduce(0,+)/Double(fitted.radii.count)) })))
                previous=current;previousTime=time
            }
    }
    func finish() -> BallSurfaceTimeline {
        timing.totalSeconds = cpuSeconds
        return BallSurfaceTimeline(entries:entries,elapsed:cpuSeconds,
            photographicExposure:exposure.estimate ?? estimator.estimate,preparationTiming:timing)
    }
}
