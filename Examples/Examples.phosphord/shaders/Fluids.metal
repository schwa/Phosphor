/* prompt: fluid simulation */

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

/// Manual bilinear sampler over a read-only texture. Reads four integer texels
/// and lerps. Clamp-to-edge to avoid wrap artifacts. Returns full state float4.
static float4 sampleBilinear(texture2d<float, access::read> tex, float2 px, float2 res)
{
    float2 p = clamp(px, float2(0.0), res - 1.0);
    float2 f = fract(p);
    int2 i0 = int2(floor(p));
    int2 i1 = int2(min(float2(i0) + 1.0, res - 1.0));

    float4 a = tex.read(uint2(i0.x, i0.y));
    float4 b = tex.read(uint2(i1.x, i0.y));
    float4 c = tex.read(uint2(i0.x, i1.y));
    float4 d = tex.read(uint2(i1.x, i1.y));

    float4 top = mix(a, b, f.x);
    float4 bot = mix(c, d, f.x);
    return mix(top, bot, f.y);
}

/// Fluid step: semi-Lagrangian advection of velocity (.rg) and dye (.b),
/// mouse force/dye injection, light swirl, and dissipation. Reads the previous
/// frame from imagePrev and writes the next state to image (ping-pong feedback).
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    if (gid.x >= uint(res.x) || gid.y >= uint(res.y)) return;

    // Seed / reset frame: start calm.
    if (uniforms.frame < 1.0 || uniforms.resized != 0u) {
        uniforms.textures.image.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    float dt = clamp(uniforms.timeDelta, 0.0, 0.033) * 60.0;
    float2 fgid = float2(gid);

    float4 self = uniforms.textures.imagePrev.read(gid);
    float2 vel = self.rg;

    // --- Advect by back-tracing in pixel space ---
    float2 backPos = fgid - vel * dt;
    float4 advected = sampleBilinear(uniforms.textures.imagePrev, backPos, res);
    vel = advected.rg;
    float dye = advected.b;

    // --- Neighbor velocities for a little swirl/diffusion ---
    uint2 l = uint2(max(int(gid.x) - 1, 0), gid.y);
    uint2 r = uint2(min(gid.x + 1u, uint(res.x) - 1u), gid.y);
    uint2 d = uint2(gid.x, max(int(gid.y) - 1, 0));
    uint2 u = uint2(gid.x, min(gid.y + 1u, uint(res.y) - 1u));
    float4 vl = uniforms.textures.imagePrev.read(l);
    float4 vr = uniforms.textures.imagePrev.read(r);
    float4 vd = uniforms.textures.imagePrev.read(d);
    float4 vu = uniforms.textures.imagePrev.read(u);

    // Curl-ish swirl: rotate velocity toward neighbor circulation.
    float curl = (vr.g - vl.g) - (vu.r - vd.r);
    vel += float2(-curl, curl) * 0.15 * dt;

    // Light diffusion of dye.
    dye = mix(dye, (vl.b + vr.b + vd.b + vu.b) * 0.25, 0.08);

    // --- Mouse force + dye injection ---
    if ((uniforms.mouseButtons & 1u) != 0u) {
        float2 m = uniforms.mouse;
        float2 diff = fgid - m;
        float dist = length(diff);
        float falloff = exp(-dist * dist / 600.0);

        float2 drag = (uniforms.mouse - uniforms.mouseClickOrigin) * 0.04;
        vel += drag * falloff * dt;
        dye += falloff * 0.9;
    }

    // --- Dissipation + stability clamps ---
    vel *= 0.99;
    dye *= 0.995;
    vel = clamp(vel, -50.0, 50.0);
    dye = clamp(dye, 0.0, 4.0);

    float4 outState = float4(vel, dye, 1.0);
    if (any(isnan(outState)) || any(isinf(outState))) {
        outState = float4(0.0, 0.0, 0.0, 1.0);
    }
    uniforms.textures.image.write(outState, gid);
}
