/* prompt: GIve me a sun with random sunspots on it */
/* prompt: And animate the sunspots */

/* phosphor:environment
output = "image"

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" } ]

[[textures]]
format = "rgba16Float"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "none"

[[uniforms]]
default = 1.0
kind = "float"
name = "sunSize"
ui = { slider = { max = 1.4, min = 0.4 } }

[[uniforms]]
default = 7.0
kind = "float"
name = "spotCount"
ui = { slider = { max = 12.0, min = 0.0 } }
*/

// Hash and noise helpers for procedural sun surface and sunspots.

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float2 hash22(float2 p) {
    float n = sin(dot(p, float2(41.0, 289.0)));
    return fract(float2(262144.0, 32768.0) * n);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        v += amp * noise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return v;
}

uint2 gid [[thread_position_in_grid]];

/// Renders a glowing sun disc with a roiling granulated surface plus a set of
/// randomly-placed dark sunspots that now wander, pulse in size, and fade in/out
/// over their lifetimes. Procedural only; writes the final color to `image`.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) * 2.0 - res) / min(res.x, res.y);
    float t = uniforms.time;

    float r = length(uv);
    float radius = 0.6 * userUniforms.sunSize;

    // Background space with subtle glow.
    float3 col = float3(0.01, 0.01, 0.02);
    float glow = exp(-max(r - radius, 0.0) * 4.0) * 0.6;
    col += float3(1.0, 0.5, 0.15) * glow;

    if (r < radius) {
        // Surface coordinates with slow turbulent motion.
        float2 sp = uv / radius;
        float2 flow = float2(t * 0.05, t * 0.03);
        float gran = fbm(sp * 6.0 + flow);
        gran += 0.5 * fbm(sp * 14.0 - flow * 1.7);

        // Base hot color modulated by granulation.
        float3 hot = mix(float3(1.0, 0.85, 0.3), float3(1.0, 0.45, 0.05), gran);
        col = hot * (0.8 + 0.4 * gran);

        // Random, animated sunspots.
        float spotMask = 0.0;
        int count = int(userUniforms.spotCount);
        for (int i = 0; i < 12; i++) {
            if (i >= count) break;
            float2 seed = float2(float(i) * 7.13, float(i) * 3.71);
            float fi = float(i);

            // Wandering position: base point plus a slow looping orbit so the
            // spot meanders across the disc rather than just jittering.
            float2 base = hash22(seed) * 2.0 - 1.0;
            base *= 0.7;
            float2 rnd = hash22(seed + 5.7);
            float spd = 0.08 + rnd.x * 0.12;
            float2 drift = float2(
                sin(t * spd + fi * 1.3) * (0.12 + rnd.y * 0.18),
                cos(t * spd * 1.27 + fi * 2.1) * (0.12 + rnd.x * 0.18));
            float2 pos = base + drift;

            // Pulsing size that breathes over time.
            float baseSz = 0.06 + hash21(seed + 1.3) * 0.12;
            float pulse = 0.7 + 0.3 * sin(t * (0.4 + rnd.y) + fi * 3.0);

            // Lifetime fade: each spot grows and fades on its own cycle.
            float life = 0.6 + 0.4 * sin(t * (0.15 + rnd.x * 0.2) + fi * 1.7);
            float sz = baseSz * pulse;

            float d = length(sp - pos);
            float spot = smoothstep(sz, sz * 0.4, d) * life;
            spotMask = max(spotMask, spot);
        }
        // Darken with a warm penumbra ring feel.
        float3 spotCol = mix(col, float3(0.25, 0.08, 0.02), spotMask);
        spotCol = mix(spotCol, float3(0.05, 0.01, 0.0), smoothstep(0.5, 1.0, spotMask));
        col = spotCol;

        // Limb darkening.
        float limb = sqrt(max(0.0, 1.0 - (r / radius) * (r / radius)));
        col *= 0.5 + 0.5 * limb;
    }

    col = clamp(col, 0.0, 1.0);
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
