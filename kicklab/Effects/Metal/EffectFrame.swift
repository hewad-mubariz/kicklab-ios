import Foundation
import CoreGraphics
import simd

/// Pixel-space frame contract shared by live/replay, exports and the render lab.
/// All GPU values use top-left coordinates and video-relative time.
nonisolated struct EffectFrame: Sendable, Equatable {
    var size: CGSize
    var center: SIMD2<Float>
    var radius: Float
    var time: Double
    var intensity: Float
    var visibility: Float = 1
    var velocity: SIMD2<Float> = .zero // radii / second
    var impact: Float = 0
    var impactAge: Float = -1 // Contact-motion cue; negative means no event.
    var style: Float = 1 // 0 none, 1 fire, 2 ice, 3 neon, 4 galaxy, 5 electric, 6 aura, 7 shadow, 8 rainbow, 9 pixel, 10 nature
    var environment: Float = 0
    var hasMaterial = false
    var trail: [SIMD4<Float>] = [] // x, y, radius, age in seconds
    var counter = false
    var burstAge: Float = 10
    var seed: Float = 0
    var tint = SIMD3<Float>(0.18, 1, 0.4)

    /// A visual down-to-up reversal cue, not a classified foot touch. Sample
    /// velocities over time windows so 30/60/120 Hz tracks behave consistently.
    /// It is derived from supplied history only, making seek/export repeatable.
    var contactMotionCue: (strength: Float, age: Float) {
        let points = (trail.filter { $0.x.isFinite && $0.y.isFinite && $0.z > 0
            && $0.w.isFinite && $0.w > 0 && $0.w < 0.85 }
            + [SIMD4(center.x, center.y, radius, 0)]).sorted { $0.w < $1.w }
        func at(_ age: Float) -> SIMD4<Float>? {
            guard let i = points.firstIndex(where: { $0.w >= age }) else { return nil }
            if abs(points[i].w - age) < 0.0001 { return points[i] }
            guard i > 0 else { return nil }
            let a = points[i-1], b = points[i], gap = b.w - a.w
            guard gap > 0, gap <= 0.045,
                  simd_distance(SIMD2(a.x,a.y), SIMD2(b.x,b.y)) < max(1,radius) * 5 else { return nil }
            return a + (b-a) * ((age-a.w)/gap)
        }
        guard points.count >= 5 else { return (0,-1) }
        // Newest valid peak wins; broad turns cannot keep restarting the burst.
        for i in 1..<(points.count-1) {
            let p = points[i], age = p.w
            guard age >= 0.06, age < 0.42,
                  p.y >= points[i-1].y, p.y > points[i+1].y,
                  let newer = at(age-0.06), let older = at(age+0.06) else { continue }
            // Require continuous observations through the whole velocity window.
            let window = points.filter { $0.w >= age-0.06 && $0.w <= age+0.06 }
            guard zip(window,window.dropFirst()).allSatisfy({ a,b in b.w-a.w <= 0.045
                && simd_distance(SIMD2(a.x,a.y),SIMD2(b.x,b.y)) < max(1,radius)*5 }) else { continue }
            let r = max(1,p.z), down = (p.y-older.y)/r/0.06, up = (newer.y-p.y)/r/0.06
            guard down > 3.5, up < -3.0 else { continue }
            return (min(1,max(0,(down-up-5)/16)),age)
        }
        return (0,-1)
    }

    /// Fixed-age emitter positions for characteristic advection and particle births.
    /// Missing tracking intervals stay empty rather than connecting across a jump.
    var emissionHistory: [SIMD4<Float>] {
        let points = (trail.filter { $0.z > 0 && $0.w > 0 } + [SIMD4(center.x, center.y, radius, 0)])
            .sorted { $0.w < $1.w }
        return (0..<33).map { index in
            let age = Float(index) / 40
            if age > Float(time) { return .zero }
            if index == 0 { return SIMD4(center.x, center.y, radius, visibility) }
            // Standalone previews without a supplied trajectory use a stationary emitter.
            if trail.isEmpty { return SIMD4(center.x, center.y, radius, visibility) }
            guard let upper = points.firstIndex(where: { $0.w >= age }), upper > 0 else { return .zero }
            let a = points[upper - 1], b = points[upper]
            let gap = b.w - a.w
            guard gap > 0, gap <= 0.085, simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)) < radius * 7 else { return .zero }
            let p = a + (b - a) * ((age - a.w) / gap)
            return SIMD4(p.x, p.y, p.z, visibility)
        }
    }

    var particleCount: Int {
        if counter { return 210 }
        switch style {
        case 1: return 240 // Embers; the flame body is the continuous field.
        case 2: return 110
        case 3: return 80
        case 4: return 320
        case 5: return 160
        case 6: return 36
        case 7: return 80
        case 8: return 145
        case 9: return 130
        case 10: return 130
        default: return 0
        }
    }

    var region: CGRect {
        if counter { return CGRect(origin: .zero, size: size) }
        if style == 1 {
            // Fire: the leaning flame around the ball, the buoyant wake along
            // the recorded path and the embers that climb above both. The
            // ember climb is the tallest feature; cover that column, not the
            // whole trail.
            let r = CGFloat(max(4, radius))
            var rect = CGRect(x: CGFloat(center.x) - r * 4.6, y: CGFloat(center.y) - r * 9.5,
                              width: r * 9.2, height: r * 12.6)
            for p in trail where p.w < 0.82 {
                let age = CGFloat(p.w), pr = CGFloat(max(4, p.z))
                let rise = pr * (age * 4.2 + age * age * 4.6)
                let spread = pr * (1.8 + age * 2.4)
                rect = rect.union(CGRect(x: CGFloat(p.x) - spread, y: CGFloat(p.y) - rise - spread - pr * 3,
                                         width: spread * 2, height: spread * 2 + pr * 3))
            }
            let clipped = rect.integral.intersection(CGRect(origin: .zero, size: size))
            return clipped.isNull || clipped.isEmpty
                ? CGRect(x: 0, y: 0, width: min(16, size.width), height: min(16, size.height)) : clipped
        }
        let pad = CGFloat(max(12, radius * (style == 1 ? 11 : 8)))
        var rect = CGRect(x: CGFloat(center.x) - pad, y: CGFloat(center.y) - pad, width: pad * 2, height: pad * 2)
        for p in trail where p.w < 0.85 {
            let spread = CGFloat(max(8, p.z * (style == 1 ? 5.5 : 4)))
            rect = rect.union(CGRect(x: CGFloat(p.x) - spread, y: CGFloat(p.y) - spread * 2,
                                    width: spread * 2, height: spread * 3))
        }
        let clipped = rect.integral.intersection(CGRect(origin: .zero, size: size))
        // An emitter outside an aspect-fill crop still needs video/background
        // compositing. Keep an empty tile rather than rejecting that frame.
        return clipped.isNull || clipped.isEmpty
            ? CGRect(x: 0, y: 0, width: min(16, size.width), height: min(16, size.height)) : clipped
    }

    var uniforms: EffectUniforms {
        let bounds = region
        return EffectUniforms(
            viewport: SIMD4(Float(size.width), Float(size.height), Float(time.truncatingRemainder(dividingBy: 4096)), intensity),
            ball: SIMD4(center.x, center.y, max(1, radius), visibility),
            motion: SIMD4(velocity.x, velocity.y, impact, style),
            region: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height)),
            control: SIMD4(Float(min(64, trail.count)), counter ? 1 : 0, burstAge, seed),
            tint: SIMD4(tint.x, tint.y, tint.z, 0),
            environment: SIMD4(environment, hasMaterial ? 1 : 0, impactAge, 0))
    }
}

/// Exactly seven float4s. Mirrored in EffectShaders.metal; no packed float3 ABI.
nonisolated struct EffectUniforms {
    var viewport: SIMD4<Float>
    var ball: SIMD4<Float>
    var motion: SIMD4<Float>
    var region: SIMD4<Float>
    var control: SIMD4<Float>
    var tint: SIMD4<Float>
    var environment: SIMD4<Float>
}
