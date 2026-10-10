// Power Shot trails, shader IDs 20–29.f Included after EffectStudies.h.
// A shot is one long, fast flight, so every look is drawn along the recorded path
// from the strike to the ball: straight behind it, tapering away, never over the ball.
// Patterns are keyed to the moment the ball passed each point ("birth"), so they stay
// fixed in the air the ball flew through while the ball moves on.

struct ShotPathFX {
    float distance;        // pixels to the nearest point of the flight
    float signedDistance;  // in local ball radii, positive on the left of travel
    float age;             // seconds since the ball was at that point
    float radius;          // ball radius there, in pixels (it shrinks with distance)
    float oldest;          // age of the far end of the trail
};

ShotPathFX shotPathFX(float2 pixel, constant FXUniforms &u, constant float4 *trail, float lifetime) {
    ShotPathFX path = {1e6f, 0, 1e6f, max(1.0f, u.ball.z), 0};
    int count = int(u.control.x);
    // Once the ball is lost the newest point is already a little old; start from its age.
    float4 next = float4(u.ball.xy, max(1.0f, u.ball.z), count > 0 ? trail[count - 1].w : 0);
    for (int i = count - 1; i >= 0; i--) {
        float4 a = trail[i];
        if (a.z <= 0 || a.w > lifetime) break;
        // A gap or a jump means tracking restarted: never bridge it.
        if (a.w - next.w > 0.09f || distance(a.xy, next.xy) > max(a.z, next.z) * 10) break;
        path.oldest = a.w;
        float2 ab = next.xy - a.xy;
        float length2 = dot(ab, ab);
        float f = length2 > 0.01f ? saturate(dot(pixel - a.xy, ab) / length2) : 1.0f;
        float2 delta = pixel - (a.xy + ab * f);
        float d = length(delta);
        if (d < path.distance) {
            float radius = max(1.0f, mix(a.z, next.z, f));
            float side = ab.x * delta.y - ab.y * delta.x;
            path.distance = d;
            path.radius = radius;
            path.age = mix(a.w, next.w, f);
            path.signedDistance = (side < 0 ? -d : d) / radius;
        }
        next = a;
    }
    return path;
}

float shotHashFX(float2 p) { return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f); }

float3 shotBlueFX(float heat) {
    return heat < 0.5f ? mix(float3(0.02f, 0.10f, 1.30f), float3(0.12f, 0.70f, 3.60f), heat / 0.5f)
                      : mix(float3(0.12f, 0.70f, 3.60f), float3(2.60f, 3.60f, 5.00f), (heat - 0.5f) / 0.5f);
}

/// Short streaks born along the flight at a steady rate, drifting sideways as they age.
/// Their length follows the ball's own speed, so harder shots throw longer sparks.
float shotSparksFX(ShotPathFX path, float birth, float now, float rate, float spread, float seed, float size) {
    float total = 0;
    float cell = floor(birth * rate);
    for (int k = -2; k <= 2; k++) {
        float c = cell + float(k);
        float sparkBirth = (c + shotHashFX(float2(c, seed))) / rate;
        float age = now - sparkBirth;
        if (age < 0.0f) continue;
        float drift = (shotHashFX(float2(c, seed + 7.0f)) - 0.5f) * 2.0f * (0.12f + age * spread);
        float along = (birth - sparkBirth) / ((0.006f + 0.008f * shotHashFX(float2(c, seed + 3.0f))) * size);
        float across = (path.signedDistance - drift) / ((0.07f + 0.08f * shotHashFX(float2(c, seed + 5.0f))) * size);
        float flicker = 0.55f + 0.45f * sin(now * 40.0f + c * 3.7f);
        total += exp(-along * along - across * across) * flicker * (0.4f + 0.6f * shotHashFX(float2(c, seed + 9.0f)));
    }
    return total;
}

float4 shotTrailFX(float2 pixel, constant FXUniforms &u, constant float4 *trail, float footprint) {
    float style = u.motion.w;
    // Juggle Flame stays tight to the ball; Ember Rush's sparks burn out sooner.
    float lifetime = style == 20 ? 0.30f : style == 23 ? 0.65f : 0.85f;
    ShotPathFX path = shotPathFX(pixel, u, trail, lifetime + 0.05f);
    // Size the whole trail from the ball as it is now, so it is thickest at the ball and
    // tapers with age. (Where it was struck the ball was nearer and larger; following that
    // would fatten the tail.) Never thinner than a share of the frame, so far shots still read.
    float scale = max(max(1.0f, u.ball.z), u.viewport.x * 0.022f) * 1.35f;
    path.signedDistance *= path.radius / scale;
    float R = max(1.0f, u.ball.z), t = u.viewport.z;
    float2 q = (pixel - u.ball.xy) / R;
    float r = length(q);
    float speed = length(u.motion.xy);
    float2 heading = speed > 0.5f ? u.motion.xy / speed : float2(0, -1);
    // Nothing leads the ball: fade out quickly in front of it.
    float behind = 1.0f - smoothstep(0.1f, 0.9f, dot(q, heading));
    // Taper along the trail's own length, so it always runs from full width at the ball
    // to a point at the far end, however long the flight has been so far.
    float s = saturate(path.age / clamp(path.oldest, 0.12f, lifetime));
    float fade = pow(1.0f - s, 1.2f);
    float d = path.distance / scale, sd = path.signedDistance;
    float aa = max(0.012f, footprint / scale * 0.6f);
    float birth = t - path.age;
    float power = 0.7f + 0.3f * saturate(speed / 20.0f);
    float3 color = 0;
    float alpha = 0;

    if (style == 20) {
        // Juggle Flame: a tight, licking flame hugging the back of the ball.
        float width = 0.12f + 0.82f * pow(1.0f - s, 0.8f);
        float churn = fireFBM3(float3(sd * 2.4f, birth * 16.0f, t * 1.6f));
        float lick = fireNoise3(float3(sd * 5.0f + 7.0f, birth * 34.0f, t * 3.2f));
        float edge = width * (0.7f + 0.55f * churn);
        float body = 1.0f - smoothstep(edge * 0.5f, edge + aa, d);
        float heat = saturate((1.0f - d / max(edge, 0.02f)) * (1.15f - s * 0.9f) + (lick - 0.5f) * 0.4f);
        float tongue = smoothstep(0.55f, 0.85f, lick) * lineFX(d - edge * 0.85f, 0.1f + 0.2f * s) * (1.0f - s);
        color = fireSpectrum(heat) * body * 0.55f * fade + fireSpectrum(0.45f) * tongue * 0.5f;
        alpha = saturate(body * (0.95f - 0.5f * s) + tongue * 0.4f);
    } else if (style == 21) {
        // Blue Jet: more flame, combed into one long straight wake.
        float width = 0.1f + 0.95f * pow(1.0f - s, 0.9f);
        float comb = fireNoise3(float3(sd * 7.5f, birth * 4.0f, t * 0.9f));
        float churn = fireFBM3(float3(sd * 2.2f, birth * 11.0f, t * 1.3f));
        float edge = width * (0.65f + 0.6f * churn);
        float body = 1.0f - smoothstep(edge * 0.4f, edge + aa, d);
        float streaks = smoothstep(0.45f, 0.8f, comb) * lineFX(d, edge * 1.2f);
        float heat = saturate((1.0f - d / max(edge, 0.02f)) * (1.1f - s * 0.85f) + streaks * 0.3f);
        color = (shotBlueFX(heat) * body * 0.5f + shotBlueFX(0.75f) * streaks * 0.35f) * fade;
        alpha = saturate((body * 0.85f + streaks * 0.3f) * (1.0f - s * 0.6f));
    } else if (style == 22) {
        // Volt Strike: a crackling bolt along the flight with short forks.
        float tick = floor(t * 24.0f);
        float jag = (fireNoise3(float3(birth * 26.0f, tick * 1.7f, 1.3f)) - 0.5f) * 1.0f
                  + (fireNoise3(float3(birth * 70.0f, tick * 2.3f, 4.1f)) - 0.5f) * 0.35f;
        float bolt = abs(sd - jag * (0.25f + 0.75f * (1.0f - fade * 0.5f)));
        float forkGate = smoothstep(0.66f, 0.74f, fireNoise3(float3(birth * 7.0f, tick * 0.9f, 8.0f)));
        float forkJag = jag + (fireNoise3(float3(birth * 40.0f, tick * 1.1f, 2.0f)) - 0.5f) * 0.9f;
        float fork = abs(sd - forkJag) ;
        float flicker = 0.75f + 0.25f * shotHashFX(float2(tick, 3.0f));
        float3 tint = float3(0.45f, 0.75f, 3.4f);
        color = (filamentFX(bolt, 0.05f + aa, tint, 1.0f) + filamentFX(fork, 0.025f + aa, tint, 0.6f) * forkGate) * fade * flicker;
        alpha = saturate((lineFX(bolt, 0.12f) + lineFX(fork, 0.06f) * forkGate * 0.6f) * fade);
    } else if (style == 23) {
        // Ember Rush: a slim line of warm sparks, thrown wider as they age.
        float sparks = shotSparksFX(path, birth, t, 60.0f, 1.4f, 11.0f, 0.55f);
        float core = lineFX(d, 0.05f + aa) * fade;
        float glow = lineFX(d, 0.35f + aa) * fade;
        color = fireSpectrum(0.86f) * sparks * 1.8f * (0.35f + 0.65f * fade) + fireSpectrum(0.6f) * core * 0.45f
              + fireSpectrum(0.45f) * glow * 0.12f;
        alpha = saturate(sparks * 0.9f * (0.35f + 0.65f * fade) + core * 0.3f + glow * 0.08f);
    } else if (style == 24) {
        // Lime Ribbon: one clean band on the flight line, brightest at the ball.
        float width = 0.04f + 0.6f * pow(1.0f - s, 0.6f);
        float band = 1.0f - smoothstep(width - aa, width + aa, d);
        float core = lineFX(d, width * 0.22f + aa);
        float halo = lineFX(d, width * 2.4f + aa);
        float3 lime = float3(1.55f, 2.45f, 0.32f);
        color = (lime * band * 0.75f + float3(3.2f, 3.9f, 1.5f) * core * 0.6f + lime * halo * 0.18f) * fade;
        alpha = saturate((band * 0.8f + halo * 0.15f) * (1.0f - s * 0.55f));
    } else if (style == 25) {
        // Ice Trail: a cold beam that sheds frost glints into the air behind it.
        float core = lineFX(d, 0.05f + 0.08f * fade + aa);
        float halo = lineFX(d, 0.35f * fade + 0.1f);
        float frost = shotSparksFX(path, birth, t, 70.0f, 2.4f, 23.0f, 0.6f);
        float twinkle = 0.6f + 0.4f * sin(t * 18.0f + birth * 90.0f);
        color = (iceSpectrum(0.85f) * core * 0.9f + iceSpectrum(0.45f) * halo * 0.3f) * fade
              + iceSpectrum(0.95f) * frost * twinkle * 0.8f * (0.3f + 0.7f * fade);
        alpha = saturate((core * 0.6f + halo * 0.2f) * fade + frost * 0.6f * fade);
    } else if (style == 26) {
        // Shockwave: a fine line with rings that burst out where the ball has passed.
        float core = lineFX(d, 0.04f + aa) * fade;
        float spacing = 0.12f, rings = 0;
        float pace = clamp(speed, 6.0f, 40.0f); // radii per second
        float index = floor(birth / spacing + 0.5f);
        for (int k = -1; k <= 1; k++) {
            float ringBirth = (index + float(k)) * spacing;
            float ringAge = t - ringBirth;
            if (ringAge < 0.04f || ringAge > 0.6f) continue;
            float along = (birth - ringBirth) * pace;
            float size = 0.8f + ringAge * 2.2f;
            float e = length(float2(along / 0.32f, sd)) / size;
            rings += lineFX(e - 1.0f, 0.045f + aa / size) * exp(-ringAge * 3.2f);
        }
        float3 tint = float3(0.55f, 1.2f, 3.2f);
        color = tint * core * 0.9f + float3(1.6f, 2.4f, 3.6f) * rings * 0.8f;
        alpha = saturate(core * 0.5f + rings * 0.7f);
    } else if (style == 27) {
        // Fire Trail: a long straight streak of fire with embers spun off it.
        float width = 0.06f + 0.62f * pow(1.0f - s, 1.1f);
        float comb = fireNoise3(float3(sd * 6.5f, birth * 5.0f, t * 1.1f));
        float churn = fireFBM3(float3(sd * 2.0f, birth * 9.0f, t * 1.4f));
        float edge = width * (0.7f + 0.5f * churn);
        float body = 1.0f - smoothstep(edge * 0.45f, edge + aa, d);
        float heat = saturate((1.0f - d / max(edge, 0.02f)) * (1.15f - s) + (comb - 0.5f) * 0.3f);
        float embers = shotSparksFX(path, birth, t, 55.0f, 1.6f, 31.0f, 0.7f);
        color = fireSpectrum(heat) * body * 0.5f * fade + fireSpectrum(0.85f) * embers * 0.7f * fade;
        alpha = saturate(body * (0.9f - 0.5f * s) + embers * 0.5f * fade);
    } else if (style == 28) {
        // Glow Trail: the juggling glow, stretched over the whole flight.
        float width = max(aa, 0.03f + 0.33f * fade);
        float body = lineFX(d, width) * fade;
        float core = lineFX(d, max(aa, width * 0.28f)) * fade;
        float halo = lineFX(d, width * 2.6f + aa) * fade;
        float energy = 0.92f + 0.08f * sin(t * 3.0f - path.age * 12.0f);
        color = float3(0.03f, 1.3f, 3.3f) * body * 0.8f * energy + float3(0.02f, 0.55f, 1.7f) * halo * 0.32f
              + float3(2.4f, 4.0f, 4.7f) * core * 0.95f;
        alpha = saturate(body * 0.5f + core * 0.3f + halo * 0.1f);
    } else {
        // Pulse Trail: evenly timed pulses of light, so the gaps widen with speed.
        float phase = fract(birth / 0.07f);
        float on = smoothstep(0.0f, 0.1f, phase) * (1.0f - smoothstep(0.45f, 0.58f, phase));
        float width = 0.05f + 0.08f * fade;
        float dash = lineFX(d, width + aa) * on;
        float halo = lineFX(d, width * 3.0f + 0.05f) * on;
        float3 violet = float3(1.6f, 0.6f, 3.8f);
        color = (violet * dash * 1.1f + float3(3.4f, 2.8f, 4.4f) * lineFX(d, width * 0.35f + aa) * on * 0.8f + violet * halo * 0.25f) * fade;
        alpha = saturate((dash * 0.75f + halo * 0.15f) * fade);
    }

    // No ring around the ball: the trail alone carries the look.
    color *= power;
    // The ball itself always stays clear.
    float face = smoothstep(0.97f, 1.05f, r);
    return float4(color * face * behind, alpha * face * behind);
}
