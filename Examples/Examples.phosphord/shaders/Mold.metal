/* prompt: fungus mold */

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

/// Gray-Scott reaction-diffusion feedback simulating a creeping fungal mold.
/// Reads previous state from imagePrev (.r = U substrate, .g = V mold),
/// writes next state into image. Edges are clamped so the colony does not
/// wrap. .b is used purely as a display luma cache and never feeds back.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    int2 res = int2(uniforms.resolution);
    if (res.x < 1 || res.y < 1) { return; }
    int2 p = int2(gid);

    // --- Seed / reset frame -------------------------------------------------
    if (uniforms.frame < 1.0 || uniforms.resized != 0u) {
        float u = 1.0;
        float v = 0.0;
        // Scatter spores.
        float n = hash13(float3(float(p.x), float(p.y), 7.0));
        if (n > 0.9975) { v = 0.6; }
        // A central seed cluster.
        float2 c = float2(res) * 0.5;
        if (distance(float2(p), c) < 6.0) { v = 0.7; u = 0.4; }
        uniforms.textures.image.write(float4(u, v, 0.0, 1.0), gid);
        return;
    }

    // --- Clamped neighbour fetch helper (inline) ----------------------------
    int xm = max(p.x - 1, 0);
    int xp = min(p.x + 1, res.x - 1);
    int ym = max(p.y - 1, 0);
    int yp = min(p.y + 1, res.y - 1);

    float4 c  = uniforms.textures.imagePrev.read(uint2(p));
    float4 l  = uniforms.textures.imagePrev.read(uint2(xm, p.y));
    float4 r  = uniforms.textures.imagePrev.read(uint2(xp, p.y));
    float4 t  = uniforms.textures.imagePrev.read(uint2(p.x, ym));
    float4 b  = uniforms.textures.imagePrev.read(uint2(p.x, yp));
    float4 tl = uniforms.textures.imagePrev.read(uint2(xm, ym));
    float4 tr = uniforms.textures.imagePrev.read(uint2(xp, ym));
    float4 bl = uniforms.textures.imagePrev.read(uint2(xm, yp));
    float4 br = uniforms.textures.imagePrev.read(uint2(xp, yp));

    float U = c.r;
    float V = c.g;

    // Reaction-diffusion update with a couple of internal iterations.
    float feed = 0.037;
    float kill = 0.06;
    float Du = 0.16;
    float Dv = 0.08;

    for (int it = 0; it < 2; it++) {
        // 9-point Laplacian (re-using neighbour samples from prev frame).
        float lapU = (l.r + r.r + t.r + b.r) * 0.2
                   + (tl.r + tr.r + bl.r + br.r) * 0.05
                   - U;
        float lapV = (l.g + r.g + t.g + b.g) * 0.2
                   + (tl.g + tr.g + bl.g + br.g) * 0.05
                   - V;

        float uvv = U * V * V;
        float dU = Du * lapU - uvv + feed * (1.0 - U);
        float dV = Dv * lapV + uvv - (kill + feed) * V;

        U = clamp(U + dU, 0.0, 1.0);
        V = clamp(V + dV, 0.0, 1.0);
    }

    // Inject mold under the mouse when the left button is held.
    if ((uniforms.mouseButtons & 1u) != 0u) {
        float d = distance(float2(p), uniforms.mouse);
        if (d < 8.0) { V = max(V, 0.7); }
    }

    // --- Display tint (cached in .b, not fed back) --------------------------
    float m = clamp(V * 1.6, 0.0, 1.0);
    float speck = 0.5 + 0.5 * snoise2D(float2(p) * 0.35 + uniforms.time * 0.05);
    // Dark brown substrate.
    float3 substrate = float3(0.06, 0.04, 0.03);
    // Fuzzy off-white / grey-green mold.
    float3 moldCol = mix(float3(0.30, 0.34, 0.22),
                         float3(0.85, 0.88, 0.78),
                         smoothstep(0.2, 0.9, m));
    moldCol *= (0.75 + 0.25 * speck);
    float3 col = mix(substrate, moldCol, smoothstep(0.05, 0.5, m));
    col = clamp(col, 0.0, 1.0);

    float luma = dot(col, float3(0.299, 0.587, 0.114));
    uniforms.textures.image.write(float4(U, V, luma, 1.0), gid);

    // NOTE: the visible color is reconstructed below via the same mapping in a
    // single pass; we store U/V/luma. To actually display color we instead
    // write color in a separate channel-safe manner: see overwrite below.
}
