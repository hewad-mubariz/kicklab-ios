// Power Shot camera pass, shared by Metal (ShotCamera.metal) and the CPU export
// (ShotCPURenderer.mm). Uniform layout matches ShotCameraFrame (ShotCameraPlan.swift):
//
//  v[0]  viewport  w, h, mode (0 off, 1 crop, 6 wide + detail, 7 duo, 8 frozen arc), path count
//  v[1]  crop      centre x, y (0-1), zoom, angle
//  v[2]  ball      lens: output x, y, ring radius, seen | chase: source x, y, radius (w-share), protect
//  v[3]  shake     dx, dy (px), directional blur length (px), blur angle
//  v[4]  grade     flash, desaturate, dim, colour split (px)
//  v[5]  lens      source x, y, zoom, on
//  v[6]  inset     lens x, y (0-1), radius (short-edge share), leader alpha
//  v[7]  ripple    output x, y, age (s), fade (0 off)
//  v[8]  radial    output x, y, strength, protected radius (px)
//  v[9]  spot      output x, y, radius (px), strength
//  v[10] focus     output x, y, radius (px), amount
//  v[11] lock      output x, y, half size (px), lock 0-1
//  v[12] lock2     alpha, -, standby, landed | split: detail rect x0, y0, x1, y1
//  v[13] split     frame line alpha, balance (1 = wide only), stacked, wide centre y
//  v[14] path      progress 0-1, alpha, end ring, -
//  v[15] misc      rewind, bicubic, stamps reveal with path, stamp alpha
//  v[16] duo       top crop centre x, y, zoom, -
//  v[17] stamps    count, path start (s), path end (s), sprite scale
//  v[18] extra     -, ripple strength, rewind seed, -
//  v[19] arc eye    x, y, z (metres; the phone sits at 0, height, 0 looking down +z), focal (px)
//  v[20] arc turn   cos, sin of the swing, principal column (px), horizon row (px)
//  v[21] arc scene  the phone's focal (px), its height, the kicker's depth, the backdrop's depth (m)
//  v[22] arc layers background fill (0 – 1), fill reach around the kicker (px), view centre offset x, y (px)
//  v[23] arc fill   softening of what other frames fill in behind the kicker (px), how far the softening fades out (px), -, -
//  In frozen-arc mode the atlas texture holds the layers: painted-out background (rgb), kicker outline (a).
#pragma once

struct ShotPick { float4 color; float stamped; };

float2 shotCameraUV(float2 pixel, float2 panel, float2 size, float4 crop) {
    float fit = max(panel.x / size.x, panel.y / size.y);
    float2 q = (pixel - panel * .5f) / (fit * crop.z);
    float c = cos(crop.w), s = sin(crop.w);
    q = float2(c * q.x + s * q.y, -s * q.x + c * q.y);
    return q / size + crop.xy;
}
float2 shotCameraToOutput(float2 uv, float2 panel, float2 size, float4 crop) {
    float fit = max(panel.x / size.x, panel.y / size.y);
    return (uv - crop.xy) * size * fit * crop.z + panel * .5f;
}
float shotCameraSegment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    return length(p - a - ab * clamp(dot(p - a, ab) / max(.001f, dot(ab, ab)), 0.f, 1.f));
}
float shotLine(float d, float width) { return 1 - smoothstep(width, width + 1.2f, d); }

/// Catmull-Rom from nine bilinear taps: crisper than bilinear when a crop is enlarged 2-4x.
float4 shotCubic(SHOT_TEXTURE tex, float2 uv) {
    float2 texSize = float2(float(tex.get_width()), float(tex.get_height()));
    float2 at = uv * texSize;
    float2 p1 = floor(at - .5f) + .5f;
    float2 f = at - p1;
    float2 w0 = f * (-.5f + f * (1.f - .5f * f));
    float2 w1 = 1.f + f * f * (-2.5f + 1.5f * f);
    float2 w2 = f * (.5f + f * (2.f - 1.5f * f));
    float2 w3 = f * f * (-.5f + .5f * f);
    float2 w12 = w1 + w2;
    float2 p0 = (p1 - 1.f) / texSize, p3 = (p1 + 2.f) / texSize, p12 = (p1 + w2 / w12) / texSize;
    float4 c = tex.sample(linear, float2(p0.x, p0.y)) * w0.x * w0.y + tex.sample(linear, float2(p12.x, p0.y)) * w12.x * w0.y
             + tex.sample(linear, float2(p3.x, p0.y)) * w3.x * w0.y
             + tex.sample(linear, float2(p0.x, p12.y)) * w0.x * w12.y + tex.sample(linear, float2(p12.x, p12.y)) * w12.x * w12.y
             + tex.sample(linear, float2(p3.x, p12.y)) * w3.x * w12.y
             + tex.sample(linear, float2(p0.x, p3.y)) * w0.x * w3.y + tex.sample(linear, float2(p12.x, p3.y)) * w12.x * w3.y
             + tex.sample(linear, float2(p3.x, p3.y)) * w3.x * w3.y;
    return float4(clamp(c.x, 0.f, 1.f), clamp(c.y, 0.f, 1.f), clamp(c.z, 0.f, 1.f), 1);
}

/// The recorded picture at `uv`, with Ball Strobe / freeze ghosts from the sprite atlas.
ShotPick shotScene(SHOT_TEXTURE source, SHOT_TEXTURE atlas, constant ShotCameraUniforms &u, constant float4 *stamps,
                   float2 uv, bool cubic) {
    ShotPick pick;
    pick.color = cubic ? shotCubic(source, uv) : source.sample(linear, uv);
    pick.stamped = 0;
    int count = int(u.v[17].x);
    float2 size = u.v[0].xy;
    for (int i = 0; i < count; i++) {
        float4 s = stamps[i];
        float r = s.z * size.x;
        float2 d = (uv - s.xy) * size;
        float dist = length(d);
        if (dist > r * 1.3f) continue;
        float alpha = u.v[15].w;
        // w packs the sprite index and, in its fraction, where along the path the ghost sits.
        if (u.v[15].z > .5f) {
            float at = fract(s.w);
            alpha *= smoothstep(at - .04f, at + .04f, u.v[14].x);
        }
        float m = (1 - smoothstep(r * .8f, r * 1.3f, dist)) * alpha;
        if (m <= 0) continue;
        // Sprite i sits in a 6 x 4 atlas; each covers the ball and a margin of `scale` radii.
        float scale = u.v[17].w;
        int index = int(floor(s.w));
        float2 cell = float2(float(index % 6), float(index / 6));
        float2 inSprite = d / (2 * r * scale) + .5f;
        float2 atlasUV = (cell + clamp(inSprite, float2(0, 0), float2(1, 1))) / float2(6, 4);
        pick.color = mix(pick.color, atlas.sample(linear, atlasUV), m * .95f);
        pick.stamped = max(pick.stamped, m);
    }
    return pick;
}

/// The whole crop pipeline for one output pixel position `q` (after shake and ripple).
float4 shotSampleAt(SHOT_TEXTURE source, SHOT_TEXTURE atlas, constant ShotCameraUniforms &u, constant float4 *stamps,
                    float2 q, bool cubic, float4 crop, float2 panel) {
    return shotScene(source, atlas, u, stamps, shotCameraUV(q, panel, u.v[0].xy, crop), cubic).color;
}

float4 shotSplitPixel(SHOT_TEXTURE source, SHOT_TEXTURE atlas, constant ShotCameraUniforms &u, constant float4 *stamps, float2 p) {
    float2 size = u.v[0].xy;
    bool stacked = u.v[13].z > .5f;
    float2 panel = stacked ? float2(size.x, size.y * u.v[13].y) : float2(size.x * u.v[13].y, size.y);
    bool wide = stacked ? p.y < panel.y : p.x < panel.x;
    float4 c;
    if (wide) {
        if (stacked) {
            // The action band of the wide shot fills its half, edge to edge.
            float4 band = float4(.5f, u.v[13].w, 1, 0);
            c = shotSampleAt(source, atlas, u, stamps, p, false, band, panel);
            float2 a = shotCameraToOutput(u.v[12].xy, panel, size, band), b = shotCameraToOutput(u.v[12].zw, panel, size, band);
            float d = min(min(abs(p.x - a.x), abs(p.x - b.x)), min(abs(p.y - a.y), abs(p.y - b.y)));
            bool inside = p.x > a.x - 2 && p.x < b.x + 2 && p.y > a.y - 2 && p.y < b.y + 2;
            if (inside) c.rgb = mix(c.rgb, float3(.80f, 1, .43f), shotLine(d, 1.6f) * .95f * u.v[13].x);
        } else {
            float fit = min(panel.x / size.x, panel.y / size.y);
            float2 uv = (p - panel * .5f) / (size * fit) + .5f;
            c = all(uv >= 0.f) && all(uv <= 1.f) ? source.sample(linear, uv) : float4(.025f, .045f, .035f, 1);
        }
    } else {
        float2 offset = stacked ? float2(0, panel.y) : float2(panel.x, 0);
        float2 detail = stacked ? float2(size.x, size.y - panel.y) : float2(size.x - panel.x, size.y);
        c = shotSampleAt(source, atlas, u, stamps, p - offset, true, u.v[1], detail);
    }
    if (u.v[13].y < .999f && abs(stacked ? p.y - panel.y : p.x - panel.x) < max(1.5f, size.x * .0025f)) c = float4(.025f, .045f, .035f, 1);
    return c;
}

/// Folds a coordinate that left the picture back into it, so unseen grass borrows nearby grass.
float shotMirror(float v, float hi) {
    if (v < 0) v = -v;
    if (v > hi) v = 2 * hi - v;
    return clamp(v, 0.f, hi);
}

/// Frozen Arc: the frozen frame as grass, a backdrop and the kicker's cut-out, seen from a camera
/// swung around him. Everything is the recording's own pixels, looked up where the phone saw them.
float4 shotArcPixel(SHOT_TEXTURE source, SHOT_TEXTURE layers, constant ShotCameraUniforms &u, float2 p) {
    float2 size = u.v[0].xy;
    float ox = u.v[19].x, oy = u.v[19].y, oz = u.v[19].z, f = u.v[19].w;
    float c = u.v[20].x, s = u.v[20].y, cx = u.v[20].z, horizon = u.v[20].w;
    float focal = u.v[21].x, height = u.v[21].y, kicker = u.v[21].z, backdrop = u.v[21].w;
    // This pixel's ray: right (c, 0, -s), up (0, 1, 0), forward (s, 0, c). The view's centre moves
    // (v[22].zw) so the swung camera only shows what the phone filmed.
    float a = (p.x - cx - u.v[22].z) / f, b = -(p.y - horizon - u.v[22].w) / f;
    float dx = c * a + s, dy = b, dz = -s * a + c;
    // Grass, or the goal and trees beyond it.
    float tg = dy < -1e-5f ? -oy / dy : 1e9f;
    float tb = dz > 1e-5f ? (backdrop - oz) / dz : 1e9f;
    float t = (oz + dz * tg) <= backdrop ? tg : tb;
    float4 color = source.sample(linear, p / size);
    if (t < 1e8f) {
        float qx = ox + dx * t, qy = oy + dy * t, qz = max(.05f, oz + dz * t);
        // Pixel centres sit at +0.5, so a point seen through pixel p projects back to p itself.
        float2 seen = float2(shotMirror(cx + focal * qx / qz, size.x), shotMirror(horizon + focal * (height - qy) / qz, size.y));
        float2 uv = seen / size;
        color = source.sample(linear, uv);
        // Where the kicker stood, the background comes from frames where he stood elsewhere.
        float2 reach = float2(u.v[22].y, u.v[22].y) / size;
        float near = layers.sample(linear, uv).a;
        for (int i = 0; i < 8; i++) {
            float angle = float(i) * .7853982f;
            near = max(near, layers.sample(linear, uv + float2(cos(angle), sin(angle)) * reach).a);
        }
        // Only where the kicker stood (and a thin rim): elsewhere the frozen frame, shadow and all, stays.
        float fill = smoothstep(.1f, .5f, near) * u.v[22].x;
        if (fill > 0) color = mix(color, float4(layers.sample(linear, uv).rgb, 1), fill);
        // What other frames fill in behind the kicker is softened, and the softening fades out over a
        // short distance, so the fill-in melts into the frozen background instead of reading as a patch
        // from another moment. Away from where he stood, the background stays sharp.
        float soft = u.v[23].x;
        if (soft > .3f && u.v[22].x > 0) {
            float2 wide = float2(u.v[23].y, u.v[23].y) / size;
            float around = near;
            for (int i = 0; i < 8; i++) {
                float angle = float(i) * .7853982f;
                around = max(around, layers.sample(linear, uv + float2(cos(angle), sin(angle)) * wide).a);
            }
            float softness = smoothstep(.05f, .5f, around) * u.v[22].x;
            if (softness > .01f) {
                float4 sum = color;
                for (int i = 0; i < 12; i++) {
                    float r = soft * sqrt((float(i) + .5f) / 12.f), angle = float(i) * 2.39996f;
                    float2 tap = uv + float2(cos(angle), sin(angle)) * r / size;
                    float4 c = source.sample(linear, tap);
                    if (fill > 0) c = mix(c, float4(layers.sample(linear, tap).rgb, 1), fill);
                    sum += c;
                }
                color = mix(color, sum / 13.f, softness);
            }
        }
    }
    // The kicker: a cut-out standing at his own depth.
    if (dz > 1e-5f) {
        float tk = (kicker - oz) / dz;
        float hy = oy + dy * tk;
        if (tk > 0 && tk < t && hy > -.02f) {
            float hx = ox + dx * tk;
            float2 seen = float2(cx + focal * hx / kicker, horizon + focal * (height - hy) / kicker);
            if (seen.x >= 0 && seen.x < size.x && seen.y >= 0 && seen.y < size.y) {
                float2 uv = seen / size;
                float alpha = layers.sample(linear, uv).a;
                if (alpha > .003f) color = mix(color, source.sample(linear, uv), alpha);
            }
        }
    }
    return color;
}

float4 shotDuoPixel(SHOT_TEXTURE source, SHOT_TEXTURE atlas, constant ShotCameraUniforms &u, constant float4 *stamps, float2 p) {
    float2 size = u.v[0].xy;
    float split = size.y * u.v[13].y;
    float4 c = p.y < split
        ? shotSampleAt(source, atlas, u, stamps, p, true, float4(u.v[16].xyz, 0), float2(size.x, split))
        : shotSampleAt(source, atlas, u, stamps, p - float2(0, split), true, u.v[1], float2(size.x, size.y - split));
    if (u.v[13].y < .999f && abs(p.y - split) < max(1.5f, size.x * .0025f)) c = float4(.025f, .045f, .035f, 1);
    return c;
}

float4 shotCameraPixel(SHOT_TEXTURE source, SHOT_TEXTURE original, SHOT_TEXTURE atlas, SHOT_TEXTURE blurred,
                       constant ShotCameraUniforms &u, constant float4 *path, constant float4 *stamps, float2 p) {
    float2 size = u.v[0].xy;
    int mode = int(u.v[0].z);
    if (mode == 6) return shotSplitPixel(source, atlas, u, stamps, p);
    if (mode == 7) return shotDuoPixel(source, atlas, u, stamps, p);
    if (mode == 8) return shotArcPixel(source, atlas, u, p);
    bool cubic = u.v[15].y > .5f;
    float2 q = p - u.v[3].xy;

    // Tape rewind: a rolling tracking band and a soft horizontal tear.
    if (u.v[15].x > .5f) {
        float band = fmod(u.v[18].z * 97.f, size.y);
        float z = (p.y - band) / 26;
        q.x += 9 * exp(-z * z) + 1.5f * sin(p.y * .11f + u.v[18].z);
    }
    // Shockwave: a refracting ring and a fainter echo leaving the contact point.
    float ringChroma = 0, ringRim = 0;
    if (u.v[7].w > 0) {
        float2 d = q - u.v[7].xy;
        float dist = max(.001f, length(d)), k = max(.3f, u.v[18].y), scale = size.x / 720.f;
        for (int e = 0; e < 2; e++) {
            float age = u.v[7].z - e * .075f;
            if (age < 0 || age > .65f) continue;
            float radius = (30 + 1650 * age) * scale, thick = (26 + 70 * age) * scale;
            float fade = pow(1 - age / .65f, 2.f) * (e == 0 ? 1 : .55f) * k * min(1.f, u.v[7].w);
            float bandPos = (dist - radius) / thick;
            float push = -bandPos * exp(-bandPos * bandPos * 2) * 30 * scale * fade;
            q -= d / dist * push;
            ringChroma += exp(-bandPos * bandPos * 2) * 4.5f * scale * fade;
            float rim = (dist - radius - thick * .35f) / (thick * .22f);
            ringRim += exp(-rim * rim) * fade;
        }
    }
    float4 crop = u.v[1];
    ShotPick pick = shotScene(source, atlas, u, stamps, shotCameraUV(q, size, size, crop), cubic);
    float4 c = pick.color;
    float ca = u.v[4].w + ringChroma;
    if (ca > .05f) {
        float2 dir = (q - size * .5f) / max(1.f, length(q - size * .5f)) * ca;
        c.r = shotSampleAt(source, atlas, u, stamps, q + dir, cubic, crop, size).r;
        c.b = shotSampleAt(source, atlas, u, stamps, q - dir, cubic, crop, size).b;
    }
    // Camera whip or shake blur along one direction; a chased ball stays crisp.
    if (u.v[3].z > .75f) {
        float2 dir = float2(cos(u.v[3].w), sin(u.v[3].w)) * u.v[3].z;
        float4 acc = float4(0, 0, 0, 0);
        for (int i = 0; i < 10; i++) acc += shotSampleAt(source, atlas, u, stamps, q + dir * (float(i) / 9 - .5f), false, crop, size);
        float keep = 0;
        if (u.v[2].w > 0 && u.v[6].z <= 0) {
            float2 ball = shotCameraToOutput(u.v[2].xy, size, size, crop);
            float rr = u.v[2].z * crop.z;
            keep = 1 - smoothstep(rr * 1.4f, rr * 2.6f, length(p - ball));
        }
        c = mix(acc / 10, c, keep);
    }
    // Launch warp / impact speed: radial blur toward the ball, ball protected.
    if (u.v[8].z > .001f) {
        float2 center = u.v[8].xy;
        float4 acc = float4(0, 0, 0, 0);
        for (int i = 0; i < 14; i++) acc += shotSampleAt(source, atlas, u, stamps, center + (q - center) * (1 - u.v[8].z * float(i) / 13), false, crop, size);
        float keep = 1 - smoothstep(u.v[8].w, u.v[8].w * 2.2f, length(p - center));
        c = mix(acc / 14, c, keep);
    }
    // Rack focus: the out-of-focus picture away from the focus point.
    if (u.v[10].w > .001f) {
        float4 soft = blurred.sample(linear, shotCameraUV(q, size, size, crop));
        float m = smoothstep(u.v[10].z, u.v[10].z * 2.6f + 40, length(p - u.v[10].xy)) * u.v[10].w;
        c = mix(c, soft, m);
    }
    // Grade: spotlight pool (or the whole frame) desaturated and dimmed; flash inside the light.
    float outside = 1 - pick.stamped;
    if (u.v[9].w > 0) outside = smoothstep(u.v[9].z * .7f, u.v[9].z * 2.3f, length(p - u.v[9].xy));
    float luma = c.r * .2126f + c.g * .7152f + c.b * .0722f;
    c.rgb = mix(c.rgb, float3(luma, luma, luma), u.v[4].y * outside);
    c.rgb *= 1 - u.v[4].z * outside;
    if (u.v[9].w > 0) c.rgb *= 1 + .22f * (1 - outside) * u.v[9].w;
    c.rgb += (1 - c.rgb) * min(1.f, ringRim) * .22f;
    float flash = u.v[4].x * (u.v[9].w > 0 ? (1 - outside) : 1);
    c.rgb += (1 - c.rgb) * flash * .75f;
    if (u.v[15].x > .5f) c.rgb *= .88f + .12f * float(fmod(p.y, 4.f) < 2);

    // Flight path, drawn on with progress: a glowing lime line with a hot core.
    int n = int(u.v[0].w);
    if (n > 1 && u.v[14].y > .001f) {
        float reach = u.v[14].x * (n - 1), d = 100000.f;
        float2 last = shotCameraToOutput(path[0].xy, size, size, crop);
        for (int i = 1; i < n; i++) {
            if (float(i - 1) >= reach) break;
            float2 a = last, b = shotCameraToOutput(path[i].xy, size, size, crop);
            last = b;
            if (float(i) > reach) b = mix(a, b, reach - float(i - 1));
            if (path[i].z > .5f) d = min(d, shotCameraSegment(p, a, b));
        }
        float w = max(1.f, size.x / 360.f);
        float glow = exp(-d * d / (2 * 9 * 9 * w * w)) * .45f, core = shotLine(d, 1.1f * w);
        c.rgb = mix(c.rgb, float3(.80f, 1, .43f), min(1.f, (core + glow) * u.v[14].y));
        c.rgb = mix(c.rgb, float3(1, 1, 1), shotLine(d, .4f * w) * u.v[14].y * .8f);
        if (u.v[14].z > .5f) {
            float ring = abs(length(p - shotCameraToOutput(path[n - 1].xy, size, size, crop)) - 7.5f * w);
            c.rgb = mix(c.rgb, float3(.80f, 1, .43f), shotLine(ring, .9f * w) * u.v[14].y);
        }
    }

    // Ball lens: a magnifier that follows the ball, tied to it by a leader line.
    if (u.v[5].w > 0 && u.v[6].z > .001f) {
        float radius = min(size.x, size.y) * u.v[6].z;
        float2 center = u.v[6].xy * size;
        float dist = length(p - center), w = max(1.f, size.x / 360.f);
        if (dist > radius && dist < radius + 11 * w) c.rgb *= 1 - .4f * (1 - smoothstep(radius, radius + 11 * w, dist));
        if (dist < radius) {
            float fit = max(size.x / float(original.get_width()), size.y / float(original.get_height()));
            float2 uv = u.v[5].xy + (p - center) / (float2(float(original.get_width()), float(original.get_height())) * fit * u.v[5].z);
            c = shotCubic(original, uv);
            c.rgb *= 1 - .22f * smoothstep(radius * .72f, radius, dist);
        }
        c.rgb = mix(c.rgb, float3(.80f, 1, .43f), shotLine(abs(dist - radius), .8f * w));
        float leader = u.v[6].w * u.v[2].w;
        if (leader > .01f) {
            float2 ball = u.v[2].xy, to = ball - center;
            float len = length(to);
            if (len > radius + u.v[2].z + 6) {
                float2 dir = to / len;
                float d = shotCameraSegment(p, center + dir * (radius + 2), ball - dir * u.v[2].z);
                c.rgb = mix(c.rgb, float3(.80f, 1, .43f), shotLine(d, .45f * w) * leader * .85f);
            }
            c.rgb = mix(c.rgb, float3(.80f, 1, .43f), shotLine(abs(length(p - ball) - u.v[2].z), .55f * w) * leader);
        }
    }

    // Target lock: corner brackets that snap onto the ball, with range ticks.
    if (u.v[11].z > 0 && u.v[12].x > .001f) {
        float2 o = p - u.v[11].xy;
        float s = u.v[11].z, arm = s * .45f, d = 100000.f, w = max(1.f, size.x / 360.f);
        for (int k = 0; k < 4; k++) {
            float2 corner = float2((k & 1) ? s : -s, (k & 2) ? s : -s);
            float2 inward = float2((k & 1) ? -arm : arm, (k & 2) ? -arm : arm);
            d = min(d, shotCameraSegment(o, corner, corner + float2(inward.x, 0)));
            d = min(d, shotCameraSegment(o, corner, corner + float2(0, inward.y)));
        }
        if (u.v[11].w > .5f) {
            float t0 = s + 3 * w, t1 = s + 8 * w;
            d = min(d, shotCameraSegment(o, float2(t0, 0), float2(t1, 0)));
            d = min(d, shotCameraSegment(o, float2(-t0, 0), float2(-t1, 0)));
            d = min(d, shotCameraSegment(o, float2(0, t0), float2(0, t1)));
            d = min(d, shotCameraSegment(o, float2(0, -t0), float2(0, -t1)));
        }
        float3 tint = u.v[12].z > .5f ? float3(1, 1, 1) : float3(.80f, 1, .43f);
        c.rgb = mix(c.rgb, tint, shotLine(d, .85f * w) * u.v[12].x);
    }
    return float4(c.rgb, 1);
}
