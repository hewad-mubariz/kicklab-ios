//
//  Shaders.metal
//  kicklab
//
//  Metal effects for the annotated replay.
//
//  These run on the annotation layer, not the video: SwiftUI shader modifiers
//  operate on SwiftUI-drawn content, and VideoPlayer is a UIKit layer underneath.
//  So the rings, trail and pulses are drawn in a Canvas and then put through
//  these, which is where the glow and the shockwave come from.
//
//  Every effect is tied to something real. The bloom's strength follows the
//  detector's confidence, the shockwave fires on a counted touch, and the trail's
//  colour follows the ball's vertical velocity - the exact signal the counter
//  keys on. A pretty overlay that means nothing would be worse than the flat one.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Neon bloom: keeps the drawn shape and adds a soft halo around it.
///
/// Sampling a ring of offsets is a cheap approximation of a gaussian blur, and
/// at the scale of a few pixels it is indistinguishable from one.
[[ stitchable ]] half4 neonBloom(float2 position,
                                 SwiftUI::Layer layer,
                                 float radius,
                                 float intensity) {
    half4 base = layer.sample(position);

    half4 halo = half4(0.0h);
    const int steps = 12;
    for (int i = 0; i < steps; i++) {
        float angle = (float(i) / float(steps)) * 6.2831853;
        float2 offset = float2(cos(angle), sin(angle));
        // Two rings, near and far, so the falloff is smooth rather than banded.
        halo += layer.sample(position + offset * radius);
        halo += layer.sample(position + offset * radius * 2.0) * 0.5h;
    }
    halo /= half(steps) * 1.5h;

    // Add the halo rather than blending, so overlapping strokes bloom brighter.
    half3 glow = halo.rgb * half(intensity) * halo.a;
    return half4(base.rgb + glow * (1.0h - base.a), base.a + halo.a * half(intensity) * 0.55h);
}

/// A shockwave ring expanding from a touch.
///
/// Drawn procedurally rather than as a shape so the edge can be soft and the
/// energy can fade with distance and age at the same time - a stroked circle
/// cannot do either.
[[ stitchable ]] half4 touchShockwave(float2 position,
                                      half4 color,
                                      float2 centre,
                                      float progress,
                                      float maxRadius,
                                      half4 tint) {
    float dist = distance(position, centre);
    float radius = maxRadius * progress;

    // A thin band at the wavefront, widening slightly as it travels.
    float thickness = 2.0 + 10.0 * progress;
    float band = 1.0 - smoothstep(0.0, thickness, abs(dist - radius));

    // Fade the whole thing out over its life.
    float life = 1.0 - progress;
    float energy = band * life * life;

    // A soft inner flash at the very start, where the touch happened.
    float flash = exp(-dist * 0.05) * exp(-progress * 9.0);

    half a = half(min(1.0, energy + flash * 0.85));
    return half4(tint.rgb, tint.a * a) * a;
}

/// Colour a trail by the ball's vertical velocity.
///
/// Falling is warm, rising is the accent green, near-stationary is dim. This is
/// the signal the counter reads to find a reversal, so the trail changing colour
/// at the bottom of an arc *is* the touch being detected, made visible.
[[ stitchable ]] half4 velocityTint(float2 position,
                                    half4 color,
                                    float velocity) {
    if (color.a < 0.01h) { return color; }

    half3 rising = half3(0.24h, 0.92h, 0.48h);
    half3 falling = half3(1.00h, 0.62h, 0.20h);
    half3 still = half3(0.55h, 0.58h, 0.62h);

    float speed = clamp(abs(velocity) / 1.6, 0.0, 1.0);
    half3 direction = velocity > 0.0 ? falling : rising;
    half3 mixed = mix(still, direction, half(speed));

    return half4(mixed * color.a, color.a);
}

/// Subtle scanline sweep, to make the overlay feel like an instrument.
///
/// Deliberately faint: it should read as texture, not decoration competing with
/// the ball.
[[ stitchable ]] half4 instrumentSweep(float2 position,
                                       half4 color,
                                       float time,
                                       float height) {
    if (color.a < 0.01h) { return color; }
    float sweep = fract((position.y / max(height, 1.0)) - time * 0.35);
    half boost = half(1.0 + 0.22 * exp(-sweep * 9.0));
    return half4(color.rgb * boost, color.a);
}

/// Soft fill under a chart line — Metal glow does the rest.
[[ stitchable ]] half4 chartGlowBoost(float2 position,
                                      half4 color,
                                      float intensity) {
    if (color.a < 0.01h) { return color; }
    half3 neon = half3(0.45h, 0.98h, 0.20h);
    half3 boosted = mix(color.rgb, neon, half(intensity) * color.a);
    return half4(boosted, color.a);
}
