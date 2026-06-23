/* prompt: water caustics */
/* prompt: whats with the rainbow? */

/* phosphor:environment
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" } ]

[[textures]]
format = "rgba32Float"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "none"
*/

uint2 gid [[thread_position_in_grid]];

/// Procedural underwater caustics. Stateless single-pass effect driven by
/// uniforms.time. The chromatic time-offset loop that split filaments into
/// red/green/blue fringes (the "rainbow") has been removed: the caustic field
/// is computed ONCE and shared across all channels, so color now comes purely
/// from the blue-green water tint. Reads no textures; writes to `image`.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    if (res.x < 1.0 || res.y < 1.0) return;

    // Normalized, aspect-corrected coordinate (Y=0 at top).
    float2 uv = float2(gid) / res;
    float2 p = uv;
    p.x *= res.x / res.y;
    p = p * 6.0;

    float t = uniforms.time * 0.7;

    // Domain-distortion: iteratively warp the coordinate and accumulate a
    // wave field, tracking how tightly the ripples converge into filaments.
    // Computed once (no per-channel time offset -> no chromatic fringing).
    float2 q = p;
    float inten = 0.0;
    float minDist = 1.0;

    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        // Warp the coordinate by sin/cos of itself plus time.
        q += float2(
            sin(q.y * 1.5 + t + fi * 0.8) + cos(q.x * 1.3 - t * 0.6),
            cos(q.x * 1.5 - t + fi * 0.7) + sin(q.y * 1.3 + t * 0.6)
        ) * 0.35;

        // Distance to a moving ripple lattice -> thin bright lines.
        float2 cell = fract(q * 0.5) - 0.5;
        float d = length(cell);
        minDist = min(minDist, d);
        inten += 0.5 + 0.5 * sin(q.x * 2.0 + q.y * 2.0 + t + fi);
    }

    // Sharpen into crisp caustic filaments.
    float caustic = clamp(1.0 - minDist * 1.8, 0.0, 1.0);
    caustic = pow(caustic, 4.0);
    float glow = pow(clamp(inten / 6.0, 0.0, 1.0), 2.5) * 0.4;

    // Single scalar intensity shared across all channels.
    float c = caustic + glow;

    // Slow large-scale brightness modulation (looking up through water).
    float ripple = 0.85 + 0.15 * sin(uv.x * 3.0 + uv.y * 2.0 - t * 1.3);
    c *= ripple;

    // Tint: deep blue-green water mixed toward bright white caustics.
    float3 deep  = float3(0.02, 0.10, 0.18);
    float3 water = float3(0.05, 0.35, 0.45);
    float lum = clamp(c, 0.0, 1.0);
    float3 base = mix(deep, water, lum * 1.5);
    float3 rgb = base + c * float3(0.7, 0.95, 1.0);

    rgb = clamp(rgb, 0.0, 1.0);
    uniforms.textures.image.write(float4(rgb, 1.0), gid);
}
