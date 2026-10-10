import CoreGraphics
import simd

extension EffectFrame {
    nonisolated static func tracked(size: CGSize, sourceSize: CGSize, style: BallStyle, intensity: Double,
                        sample: BallStyleSample, trail: [BallStyleSample], time: Double) -> EffectFrame {
        let crop = EffectVideoGeometry.aspectFillRect(source: sourceSize, destination: size)
        func position(_ s: BallStyleSample) -> SIMD2<Float> {
            SIMD2(Float(crop.minX + s.center.x * crop.width), Float(crop.minY + s.center.y * crop.height))
        }
        let radius = Float(max(1, sample.pixelRadius(in: crop.size)))
        let valid = trail.filter { time - $0.time >= 0 && time - $0.time < 0.85 && $0.visibility > 0.1 }
        let history = valid.suffix(64).map { point in
            let p = position(point)
            return SIMD4(p.x, p.y, Float(point.pixelRadius(in: crop.size)), Float(time - point.time))
        }
        var velocity = SIMD2<Float>.zero
        var impact: Float = 0
        if let past = valid.last(where: { time - $0.time >= 0.05 && time - $0.time < 0.13 }) {
            velocity = (position(sample) - position(past)) / (radius * Float(time - past.time))
            velocity = simd_clamp(velocity, SIMD2(repeating: -32), SIMD2(repeating: 32))
        }
        // Touch / bounce cue for ice shatter & fire punch — screen +y is down.
        // Scan recent trail so the shatter envelope lingers (~0.22s) instead of one frame.
        let ordered = Array(valid.suffix(24))
        for i in 1..<max(1, ordered.count - 1) {
            let mid = ordered[i], newer = ordered[i + 1], older = ordered[i - 1]
            let dtNew = Float(newer.time - mid.time), dtOld = Float(mid.time - older.time)
            guard dtNew > 0.02, dtNew < 0.12, dtOld > 0.02, dtOld < 0.12 else { continue }
            let up = (position(newer) - position(mid)) / (radius * dtNew)
            let down = (position(mid) - position(older)) / (radius * dtOld)
            guard down.y > 3, up.y < -1.5 else { continue }
            let strength = min(1, (down.y - up.y) / 28)
            let age = Float(time - mid.time)
            let linger = exp(-age * 4.6) // ~0.22s readable burst
            impact = max(impact, strength * linger)
        }
        let speed = simd_length(velocity)
        if speed > 10 { impact = max(impact, min(0.55, (speed - 10) / 22)) }
        if let vy = sample.velocityY, let past = valid.last(where: { time - $0.time >= 0.05 && time - $0.time < 0.12 }),
           let pvy = past.velocityY, pvy > 0.35, vy < -0.12 {
            impact = max(impact, Float(min(1, (pvy - vy) / 2.2)))
        }
        var frame = EffectFrame(size: size, center: position(sample), radius: radius, time: time,
            intensity: Float(min(1, max(0, intensity))), visibility: Float(sample.visibility), velocity: velocity,
            impact: impact, style: style.shaderID, trail: history)
        if style == .neon || style == .galaxy || style == .aura || style == .rainbow {
            let cue = frame.contactMotionCue
            frame.impact = cue.strength
            frame.impactAge = cue.age
        }
        if style == .heatPulse {
            // Speed and direction changes alone are not confirmed touches.
            frame.impact = 0
            frame.impactAge = -1
        }
        return frame
    }
    nonisolated static func video(size: CGSize, sourceSize: CGSize, edit: SessionEditState,
                                 track: BallEffectTrack, time: Double) -> EffectFrame {
        var frame: EffectFrame
        if let sample = track.sample(at: time) {
            frame = .tracked(size: size, sourceSize: sourceSize, style: edit.style,
                intensity: edit.style == .none ? 0 : edit.intensity, sample: sample, trail: track.trail(at: time, duration: 0.84), time: time)
        } else {
            frame = EffectFrame(size: size, center: SIMD2(Float(size.width/2), Float(size.height/2)), radius: 1,
                                time: time, intensity: 0, visibility: 0, style: edit.style.shaderID)
        }
        frame.environment = edit.environment.shaderAmount
        if edit.style == .heatPulse, frame.visibility > 0,
           let touch = track.latestTouch(at: time), time - touch < 0.60 {
            frame.impact = 1
            frame.impactAge = Float(time - touch)
        }
        return frame
    }
}
