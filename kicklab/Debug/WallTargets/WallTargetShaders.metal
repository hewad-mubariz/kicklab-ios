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

// Brick Blast: a time-independent stone material. There are no animated noise
// octaves or full-screen effects competing with camera inference between hits.
static float brickHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float brickNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(brickHash(i), brickHash(i + float2(1, 0)), u.x),
               mix(brickHash(i + float2(0, 1)), brickHash(i + 1.0), u.x), u.y);
}

static float brickSegment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    return length(p - a - ab * clamp(dot(p - a, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0));
}

static float brickFracture(float2 uv, float2 origin, float seed) {
    float nearest = 10.0;
    // Six irregular branches anchored to the confirmed contact coordinate.
    for (int i = 0; i < 6; ++i) {
        float a = float(i) * 1.0472 + seed * 0.38;
        float2 dir = float2(cos(a), sin(a)), side = float2(-dir.y, dir.x);
        float2 p1 = origin + dir * 0.17 + side * (brickHash(float2(i, seed)) - 0.5) * 0.18;
        float2 p2 = origin + dir * 0.42 - side * 0.055;
        float2 p3 = origin + dir * 1.3 + side * 0.13;
        nearest = min(nearest, brickSegment(uv, origin, p1));
        nearest = min(nearest, brickSegment(uv, p1, p2));
        nearest = min(nearest, brickSegment(uv, p2, p3));
    }
    return nearest;
}

[[ stitchable ]] half4 wallBrickMaterial(float2 position, half4 color, float2 size,
                                         half4 tint, float seed, float damage,
                                         float broken, float2 impact) {
    float2 uv = position / max(size, float2(1.0));
    float2 p = (uv - 0.025) / 0.95;
    float2 edge = min(p, 1.0 - p);
    float bevel = min(min(edge.x, edge.y),
                      min(min(p.x + p.y, 2.0 - p.x - p.y),
                          min(p.x + 1.0 - p.y, 1.0 - p.x + p.y)) * 0.7071 - 0.035);
    float aa = max(1.0 / size.y, 0.001);
    float roughEdge = (brickNoise(p * float2(47, 38) + seed * 17) - 0.5) * 0.006;
    bevel += roughEdge;
    float silhouette = smoothstep(-aa, aa, bevel);
    if (silhouette < 0.001) { return half4(0); }

    float3 base = float3(tint.rgb);
    if (broken > 0.5) { return half4(0); } // A destroyed target really disappears.

    // Large-scale plaster/stone relief survives projector blur. No dark panel
    // border: a projector cannot darken a wall already lit by the room lights.
    float coarse = brickNoise(p * float2(9, 5) + seed * 23.0);
    float relief = brickNoise(p * float2(26, 15) + seed * 7.0);
    float grain = brickHash(floor(position * 0.65) + seed);
    float3 body = base * (0.92 + coarse * 0.14 + relief * 0.04);
    body = mix(body, float3(1.0), 0.07 + (1.0 - p.y) * 0.09);
    body += (grain - 0.5) * 0.025;

    // A handful of coarse, irregular surface fissures. These are masonry
    // detail, distinct from the radial fracture caused by a real hit.
    for (int i = 0; i < 3; ++i) {
        float h = brickHash(float2(seed * 5.1, i * 13.7));
        float2 start = float2(0.12 + h * 0.76, (i % 2 == 0) ? 0.02 : 0.98);
        float sign = (i % 2 == 0) ? 1.0 : -1.0;
        float2 previous = start;
        for (int j = 1; j <= 5; ++j) {
            float f = float(j) / 5.0;
            float bend = brickHash(float2(seed * 9.7 + i, j * 11.3)) - 0.5;
            float2 next = start + float2((h - 0.5) * f * 0.25 + bend * 0.055,
                                        sign * f * (0.18 + h * 0.27));
            float seam = brickSegment(p, previous, next);
            float width = mix(0.006, 0.0015, f);
            float shadow = 1.0 - smoothstep(width * 0.45, width + aa * 0.6, seam);
            body = mix(body, base * 0.26, shadow * 0.85);
            float lit = exp(-abs(seam - width - 0.007) * 330.0);
            body = mix(body, float3(1.0), lit * 0.26 * (1.0 - f * 0.5));
            previous = next;
        }
    }
    // Static bump lighting supplies shallow stone relief at projector scale.
    float bump = brickNoise(p * float2(26, 15) + seed * 7.0 + float2(0.12, 0.18)) - relief;
    body += bump * 0.20;
    // Sparse chips and broad facets, not a uniformly noisy square.
    float chips = step(0.75, relief) * (1.0 - smoothstep(0.01, 0.15, bevel));
    body = mix(body, base * 0.45, chips * 0.6);
    float top = 1.0 - smoothstep(0.0, 0.12, p.y);
    float left = 1.0 - smoothstep(0.0, 0.07, p.x);
    float bottom = 1.0 - smoothstep(0.0, 0.13, 1.0 - p.y);
    float face = smoothstep(0.045, 0.088, bevel);
    float3 lip = mix(base * (0.72 - bottom * 0.26), float3(1.0), 0.06 + top * 0.66 + left * 0.12);
    body = mix(lip, body, face);
    float ridge = exp(-abs(bevel - 0.068) * 210.0);
    body = mix(body, float3(1.0), ridge * (0.10 + top * 0.42 + left * 0.12));

    if (damage > 0.5) {
        float2 origin = clamp((impact - 0.025) / 0.95, float2(0.0), float2(1.0));
        float crack = brickFracture(p, origin, seed);
        float split = 1.0 - smoothstep(0.010, 0.022, crack);
        float freshEdge = exp(-abs(crack - 0.030) * 160.0);
        body = mix(body, base * 0.05, split * 0.97);
        body = mix(body, float3(1.0, 0.96, 0.72), freshEdge * 0.88);
        float crater = (1.0 - smoothstep(0.01, 0.07, length(p - origin))) * 0.62;
        body *= 1.0 - crater;
    }
    return half4(half3(saturate(body) * silhouette), half(silhouette));
}
