//
//  WallTargetShaders.metal
//  kicklab
//
//  The projected wall-target boxes, drawn on the GPU so their glow is real
//  light falloff rather than stacked shadows. A projector can only add light,
//  so everything here is bright and additive: on a light wall the dark parts
//  simply read as bare wall.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// One target box, drawn analytically from a rounded-rectangle distance field.
///
/// Apply as a colorEffect to a rectangle `pad` larger than the box on every
/// side: inside the box it paints a lit body (bright top, rich middle, a lifted
/// bottom), a soft inner glow, a slow diagonal shimmer and a rim light along
/// the edge; outside it paints a glow that falls off exponentially into the
/// gaps. Returns premultiplied colour, so with additive blending neighbouring
/// glows sum like light. `energy` 0...1 flares the box white for a hit.
[[ stitchable ]] half4 wallTargetBox(float2 position,
                                     half4 color,
                                     float2 size,
                                     float pad,
                                     float corner,
                                     half4 tint,
                                     float time,
                                     float energy,
                                     float rimWidth) {
    float2 halfBox = size * 0.5 - pad;
    float2 p = position - size * 0.5;
    float2 q = abs(p) - (halfBox - corner);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;   // < 0 inside

    float3 c = float3(tint.rgb);
    if (d > 0.0) {
        float glow = exp(-d / (pad * 0.35)) * (0.8 + 0.2 * energy);
        return half4(half3(c * glow), half(glow));
    }

    float2 uv = (p + halfBox) / (2.0 * halfBox);
    // Lit body: brightest at the top, the pure colour through the middle,
    // lifted again at the bottom so it never shades towards dark.
    float3 body = mix(mix(c, float3(1.0), 0.55), c, smoothstep(0.0, 0.55, uv.y));
    body = mix(body, mix(c, float3(1.0), 0.22), smoothstep(0.72, 1.0, uv.y));
    // Inner glow towards the centre.
    float centre = saturate(1.0 - length((uv - 0.5) * float2(1.0, 1.35)) * 1.4);
    body += c * 0.18 * centre;
    // Slow diagonal shimmer sweeping across every few seconds.
    float band = uv.x + uv.y * 0.6 - fract(time * 0.22) * 2.6 + 0.4;
    body += exp(-band * band * 30.0) * 0.3;
    // Rim light just inside the edge.
    body = mix(body, float3(1.0), exp(d / rimWidth) * 0.6);
    // Hit flare.
    body = mix(body, float3(1.0), energy * 0.85);
    return half4(half3(saturate(body)), 1.0h);
}
