/* prompt: lightning bolts and sparks */

/* phosphor:environment
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" }, { access = "read", id = "image", name = "imagePrev" } ]

[[textures]]
format = "rgba32Float"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "endOfFrame"
*/

uint2 gid [[thread_position_in_grid]];

// Distance from point p to a vertical jagged lightning path.
// The path's horizontal position at height y is driven by layered simplex
// noise plus a per-bolt seed; returns the min distance over a sampled set.
static float boltDistance(float2 p, float seed, float t, float amp, float yTop, float yBot)
{
    float best = 1e9;
    // March down the path in y, build segments, accumulate nearest distance.
    const int N = 28;
    float2 prev = float2(0.0);
    for (int i = 0; i <= N; ++i) {
        float f = float(i) / float(N);
        float y = mix(yTop, yBot, f);
        // taper amplitude toward the endpoints so it anchors
        float taper = sin(f * PI);
        float x = 0.0;
        x += snoise2D(float2(y * 6.0 + seed, t * 0.7)) * amp * taper;
        x += snoise2D(float2(y * 14.0 + seed * 1.7, t * 1.3)) * amp * 0.45 * taper;
        x += snoise2D(float2(y * 30.0 + seed * 2.3, t * 2.1)) * amp * 0.22 * taper;
        float2 cur = float2(x, y);
        if (i > 0) {
            // distance from p to segment (prev -> cur)
            float2 pa = p - prev;
            float2 ba = cur - prev;
            float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
            float d = length(pa - ba * h);
            best = min(best, d);
        }
        prev = cur;
    }
    return best;
}

/// Lightning feedback pass. Reads the previous frame from imagePrev, decays it
/// into a glowing afterimage, additively draws flickering forked bolts plus
/// scattered sparks, and writes the result to image.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    if (res.x < 1.0 || res.y < 1.0) return;

    // Re-seed to black on first frame / resize.
    if (uniforms.frame < 1.0 || uniforms.resized != 0u) {
        uniforms.textures.image.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    float t = uniforms.time;

    // Aspect-correct uv centered, y down -> flip so up is positive.
    float2 uv = (float2(gid) - 0.5 * res) / res.y;
    uv.y = -uv.y;

    // Decay the previous glow (strobing afterimage).
    float4 prev = uniforms.textures.imagePrev.read(gid);
    float3 col = prev.rgb * 0.80;

    // Flicker gating: hashed time buckets so bolts strike intermittently.
    float bucket = floor(t * 9.0);
    float flash = step(0.45, fsnoise(float2(bucket, 1.0)));
    float subFlash = 0.5 + 0.5 * sin(t * 60.0 + fsnoise(float2(bucket, 7.0)) * 10.0);

    float3 energy = float3(0.0);

    if (flash > 0.5) {
        float boltSeed = floor(t * 9.0) * 3.17;

        // Main bolt.
        float d = boltDistance(uv, boltSeed, t, 0.28, 0.62, -0.62);
        float core = 0.0035 / (d + 0.0008);
        float halo = 0.020 / (d * d * 40.0 + 0.02);
        float3 boltCol = float3(0.55, 0.7, 1.0);
        energy += (core * float3(1.0) + halo * boltCol) * subFlash;

        // Two forked branches, offset seed, shorter.
        for (int b = 0; b < 2; ++b) {
            float bs = boltSeed + 11.0 + float(b) * 5.0;
            float yStart = 0.35 - float(b) * 0.25;
            float db = boltDistance(uv, bs, t, 0.18, yStart, yStart - 0.55);
            float bcore = 0.0022 / (db + 0.0009);
            float bhalo = 0.010 / (db * db * 60.0 + 0.03);
            energy += (bcore * float3(0.9, 0.95, 1.0) + bhalo * boltCol) * subFlash * 0.7;
        }

        // Sparks scattered along the bolt path.
        for (int s = 0; s < 10; ++s) {
            float fs = float(s);
            float sy = mix(0.6, -0.6, fs / 9.0);
            float sx = snoise2D(float2(sy * 6.0 + boltSeed, t * 0.7)) * 0.28 * sin((fs / 9.0) * PI);
            // drift outward and fade with time within the bucket
            float life = fract(t * 9.0);
            float ang = fsnoise(float2(fs, bucket)) * PI2;
            float spread = (0.02 + 0.10 * life);
            float2 sp = float2(sx, sy) + float2(cos(ang), sin(ang)) * spread;
            float ds = length(uv - sp);
            float spark = 0.0009 / (ds * ds * 30.0 + 0.0015);
            spark *= (1.0 - life);
            energy += spark * float3(1.0, 0.85, 0.6);
        }
    }

    col += energy;

    // Clamp to avoid inf/NaN blooming out of control.
    col = clamp(col, 0.0, 8.0);

    uniforms.textures.image.write(float4(col, 1.0), gid);
}

