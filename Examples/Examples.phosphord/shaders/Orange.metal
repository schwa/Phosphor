/* prompt: a sdf rendered sphere with releastic lighting and a orange skin style texture */
/* prompt: put another next to it and use that blende oerator to make them merge */
/* prompt: make the rotation a user slider not timer based */
/* prompt: make the distance between them another slider */

/* phosphor:environment
flipY = true
output = "image"

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

[[uniforms]]
default = 0.8
kind = "float"
name = "rotation"
ui = { slider = { max = 6.28319, min = 0.0 } }

[[uniforms]]
default = 0.9
kind = "float"
name = "separation"
ui = { slider = { max = 1.6, min = 0.3 } }
*/

uint2 gid [[thread_position_in_grid]];

/// Orange-peel bump field: high-frequency dimples summed from value noise.
/// Negative because pits push the surface inward.
static float orangeBumps(float3 p)
{
    float b = 0.0;
    b += valueNoise3D(p * 14.0) * 0.5;
    b += valueNoise3D(p * 28.0 + 7.3) * 0.25;
    b += valueNoise3D(p * 55.0 + 3.1) * 0.12;
    // Sharpen into pits.
    b = b - 0.45;
    return b * 0.045;
}

/// Polynomial smooth-min: fuses two SDF distances over a width k.
static float smin(float a, float b, float k)
{
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// Signed distance to two bumpy oranges blended with smin (metaball merge).
/// `sep` is the half-distance between the lobe centers, from the user slider.
/// Each lobe samples orangeBumps in its own local frame so peel rides along.
static float mapScene(float3 p, float sep)
{
    float3 cL = float3(-sep, 0.0, 0.0);
    float3 cR = float3( sep, 0.0, 0.0);

    float3 pL = p - cL;
    float3 pR = p - cR;

    float dL = length(pL) - 1.0 + orangeBumps(pL);
    float dR = length(pR) - 1.0 + orangeBumps(pR);

    return smin(dL, dR, 0.6);
}

/// Central-difference normal of the combined SDF so peel detail and the
/// merge bridge both affect shading. `sep` is the slider-driven separation.
static float3 calcNormal(float3 p, float sep)
{
    float2 e = float2(0.0018, 0.0);
    float3 n = float3(
        mapScene(p + e.xyy, sep) - mapScene(p - e.xyy, sep),
        mapScene(p + e.yxy, sep) - mapScene(p - e.yxy, sep),
        mapScene(p + e.yyx, sep) - mapScene(p - e.yyx, sep));
    return normalize(n);
}

/// Renders two raymarched orange spheres merging via smin into `image`.
/// Camera orbit angle is driven by the `rotation` user slider and the lobe
/// separation by the `separation` user slider (both no longer time-based).
/// No inputs; fully procedural. GLSL convention (flipY = true).
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (2.0 * float2(gid) - res) / max(res.y, 1.0);

    // Orbiting camera, angle from the user slider instead of time.
    float t = userUniforms.rotation;
    float3 ro = float3(sin(t) * 3.8, 1.2, cos(t) * 3.8);
    float3 ta = float3(0.0);
    float3 fw = normalize(ta - ro);
    float3 rt = normalize(cross(float3(0.0, 1.0, 0.0), fw));
    float3 up = cross(fw, rt);
    float3 rd = normalize(uv.x * rt + uv.y * up + 1.6 * fw);

    // Lobe separation from the user slider.
    float sep = userUniforms.separation;

    // Sphere trace.
    float tHit = 0.0;
    bool hit = false;
    int steps = 0;
    for (int i = 0; i < 64; i++) {
        steps = i;
        float3 p = ro + rd * tHit;
        float d = mapScene(p, sep);
        if (d < 0.001) { hit = true; break; }
        tHit += d;
        if (tHit > 14.0) break;
    }

    // Background gradient.
    float3 col = mix(float3(0.18, 0.12, 0.08), float3(0.04, 0.03, 0.05),
                     clamp(uv.y * 0.5 + 0.5, 0.0, 1.0));

    if (hit) {
        float3 p = ro + rd * tHit;
        float3 n = calcNormal(p, sep);

        // Pick the nearer lobe's local frame for the peel albedo.
        float3 pL = p - float3(-sep, 0.0, 0.0);
        float3 pR = p - float3( sep, 0.0, 0.0);
        float3 pLocal = (length(pL) < length(pR)) ? pL : pR;

        float pit = clamp(orangeBumps(pLocal) / 0.045 + 0.45, 0.0, 1.0);
        float3 albedo = mix(float3(0.85, 0.30, 0.03),
                            float3(1.0, 0.55, 0.08), pit);

        float3 ldir = normalize(float3(0.8, 0.9, 0.4));
        float3 v = normalize(ro - p);
        float3 h = normalize(ldir + v);

        float diff = max(dot(n, ldir), 0.0);
        float spec = pow(max(dot(n, h), 0.0), 48.0);
        float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);
        float ao = 1.0 - float(steps) / 64.0;

        float3 ambient = float3(0.10, 0.07, 0.06);
        col = albedo * (ambient + diff * float3(1.0, 0.95, 0.85)) * ao;
        col += spec * float3(1.0, 0.9, 0.7) * 0.7;          // waxy highlight
        col += fres * float3(1.0, 0.6, 0.25) * 0.35;        // rim sheen
    }

    // Tone-map + gamma.
    col = col / (col + 1.0);
    col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
