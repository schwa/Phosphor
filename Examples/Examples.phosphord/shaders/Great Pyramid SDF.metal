/* prompt: the great pyramid - rendered as SDF. use realistic lighting. */
/* prompt: add clouds */
/* prompt: shadows */

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

// --- Scene SDF: square-based pyramid on a desert ground plane. ---
// Returns float2(distance, materialID): 1 = limestone, 2 = sand.
static float2 mapScene(float3 p)
{
    float ground = p.y;
    float2 res = float2(ground, 2.0);

    float3 q = p;
    q.xz = abs(q.xz);
    float halfBase = 1.0;
    float height = 1.27;
    float2 n = normalize(float2(height, halfBase));
    float face = dot(float2(q.x - halfBase, q.y), n);
    float faceZ = dot(float2(q.z - halfBase, q.y), n);
    float slant = max(face, faceZ);
    float pyr = max(slant, -p.y);
    if (pyr < res.x) res = float2(pyr, 1.0);

    return res;
}

static float3 calcNormal(float3 p)
{
    float2 e = float2(0.0015, 0.0);
    float d = mapScene(p).x;
    float3 n = float3(
        mapScene(p + e.xyy).x - d,
        mapScene(p + e.yxy).x - d,
        mapScene(p + e.yyx).x - d);
    return normalize(n + 1e-6);
}

static float softShadow(float3 ro, float3 rd, float k)
{
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 48; i++) {
        float h = mapScene(ro + rd * t).x;
        if (h < 0.001) return 0.0;
        res = min(res, k * h / t);
        t += clamp(h, 0.01, 0.5);
        if (t > 30.0) break;
    }
    return clamp(res, 0.0, 1.0);
}

static float calcAO(float3 p, float3 n)
{
    float occ = 0.0, sca = 1.0;
    for (int i = 0; i < 5; i++) {
        float hr = 0.02 + 0.12 * float(i);
        float d = mapScene(p + n * hr).x;
        occ += (hr - d) * sca;
        sca *= 0.7;
    }
    return clamp(1.0 - 1.5 * occ, 0.0, 1.0);
}

// Cloud shadow: marches the sun ray from a surface point to the drifting
// cloud plane (same fbm field as skyWithClouds) and dims the sun where the
// cloud cover is dense. Returns a multiplier in [0.3, 1.0].
static float cloudShadow(float3 p, float3 sunDir, float time)
{
    float planeY = 5.0;
    if (sunDir.y < 0.05) return 1.0;            // sun near horizon: skip
    float d = (planeY - p.y) / sunDir.y;        // param to cloud plane
    if (d < 0.0) return 1.0;
    float3 hitP = p + sunDir * d;
    // Match skyWithClouds coordinate transform so shadows align with clouds.
    float3 sp = hitP * 0.18 + float3(time * 0.04, 0.0, time * 0.025);
    float density = fbm3D(sp);
    float cov = smoothstep(0.45, 0.75, density);
    return clamp(1.0 - 0.7 * cov, 0.0, 1.0);
}

static float3 baseSky(float3 rd)
{
    float t = clamp(rd.y * 0.5 + 0.5, 0.0, 1.0);
    float3 horizon = float3(0.80, 0.78, 0.66);
    float3 zenith  = float3(0.30, 0.50, 0.85);
    return mix(horizon, zenith, pow(t, 0.7));
}

// Sky with drifting volumetric clouds. Projects the ray onto a high cloud
// plane, samples fbm for coverage, and blends lit cloud color over the sky.
static float3 skyWithClouds(float3 rd, float time, float3 sunDir, float3 sunCol)
{
    float3 sky = baseSky(rd);

    if (rd.y > 0.04) {
        float planeY = 5.0;
        float dist = planeY / rd.y;
        float3 hitP = rd * dist;

        float3 sp = hitP * 0.18 + float3(time * 0.04, 0.0, time * 0.025);
        float density = fbm3D(sp);

        float cov = smoothstep(0.45, 0.75, density);
        float horizonFade = smoothstep(0.04, 0.30, rd.y);
        cov *= horizonFade;

        float lightAmt = 0.5 + 0.5 * clamp(dot(rd, sunDir), 0.0, 1.0);
        float3 cloudLit = mix(float3(0.78, 0.80, 0.86), sunCol, 0.35 * lightAmt);
        float3 cloudShade = float3(0.55, 0.56, 0.62);
        float shade = smoothstep(0.4, 0.9, density);
        float3 cloudCol = mix(cloudShade, cloudLit, shade);

        sky = mix(sky, cloudCol, clamp(cov, 0.0, 1.0));
    }

    return sky;
}

/// Raymarches a square-based pyramid SDF on desert sand with a warm
/// directional sun, soft geometric shadows, AO, sky ambient, fog, drifting
/// volumetric clouds AND moving cloud shadows cast on the surface.
/// Procedural, no inputs; writes the lit color to `image`.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) * 2.0 - res) / res.y;
    uv.y = -uv.y;

    float ang = uniforms.time * 0.12 + 0.6;
    float3 ro = float3(sin(ang) * 5.2, 2.3, cos(ang) * 5.2);
    float3 ta = float3(0.0, 0.9, 0.0);
    float3 fwd = normalize(ta - ro);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + 1.6 * fwd);

    float3 sunDir = normalize(float3(0.55, 0.75, 0.35));
    float3 sunCol = float3(1.35, 1.15, 0.85);

    float t = 0.0;
    float matID = 0.0;
    bool hit = false;
    for (int i = 0; i < 96; i++) {
        float3 p = ro + rd * t;
        float2 m = mapScene(p);
        if (m.x < 0.001 * t || t > 40.0) { matID = m.y; hit = (m.x < 0.01 * t + 0.001); break; }
        t += m.x;
    }

    float3 col;
    if (hit && t < 40.0) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p);

        float3 base;
        if (matID < 1.5) {
            float v = 0.5 + 0.5 * snoise3D(p * 1.5);
            base = mix(float3(0.62, 0.52, 0.36), float3(0.78, 0.68, 0.50), v);
        } else {
            float v = 0.5 + 0.5 * snoise3D(p * 0.8);
            base = mix(float3(0.72, 0.60, 0.40), float3(0.85, 0.74, 0.52), v);
        }

        float dif = clamp(dot(n, sunDir), 0.0, 1.0);
        float sh = softShadow(p + n * 0.01, sunDir, 12.0);
        float ao = calcAO(p, n);
        float cShadow = cloudShadow(p, sunDir, uniforms.time);
        float sunVis = sh * cShadow;            // geometric AND cloud occlusion

        float sky = clamp(0.5 + 0.5 * n.y, 0.0, 1.0);
        float bounce = clamp(0.3 - 0.3 * n.y, 0.0, 1.0);

        float3 h = normalize(sunDir - rd);
        float spec = pow(clamp(dot(n, h), 0.0, 1.0), 24.0) * dif * sunVis;

        float3 lin = float3(0.0);
        lin += sunCol * dif * sunVis;
        lin += float3(0.35, 0.45, 0.60) * sky * ao;
        lin += float3(0.45, 0.35, 0.22) * bounce * ao;

        col = base * lin;
        col += sunCol * spec * 0.4;

        float fog = 1.0 - exp(-0.012 * t * t * 0.05);
        col = mix(col, skyWithClouds(rd, uniforms.time, sunDir, sunCol), clamp(fog, 0.0, 0.85));
    } else {
        col = skyWithClouds(rd, uniforms.time, sunDir, sunCol);
        float s = clamp(dot(rd, sunDir), 0.0, 1.0);
        col += sunCol * pow(s, 250.0) * 1.5;
        col += sunCol * 0.15 * pow(s, 8.0);
    }

    col = col / (col + 1.0);
    col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));

    uniforms.textures.image.write(float4(col, 1.0), gid);
}
