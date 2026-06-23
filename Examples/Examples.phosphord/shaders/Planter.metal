/* prompt: an SDF plant pot. with realistic lighting */
/* prompt: bummer. add a very subtle texture to the planter */
/* prompt: if there's a texture its too subtle */
/* prompt: now that's too dirty. looks less like a texture and more like dirt */

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

// --- SDF primitives ---------------------------------------------------------

// Capped cone aligned to Y axis, between heights -h and +h with radii rb (bottom) and rt (top).
static float sdCappedCone(float3 p, float h, float rb, float rt) {
    float2 q = float2(length(p.xz), p.y);
    float2 k1 = float2(rt, h);
    float2 k2 = float2(rt - rb, 2.0 * h);
    float2 ca = float2(q.x - min(q.x, (q.y < 0.0) ? rb : rt), abs(q.y) - h);
    float2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0, 1.0);
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}

static float sdCappedCylinder(float3 p, float h, float r) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

static float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

// Scene: returns distance in .x and material id in .y (0 ground, 1 pot, 2 soil).
static float2 mapScene(float3 p) {
    // Ground plane
    float ground = p.y + 1.0;
    float2 res = float2(ground, 0.0);

    // Pot body: hollow truncated cone, wider at top.
    float3 q = p;
    float outer = sdCappedCone(q, 0.85, 0.6, 0.85);
    float inner = sdCappedCone(q - float3(0.0, 0.18, 0.0), 0.85, 0.5, 0.78);
    float body = max(outer, -inner);
    // Rim lip
    float lip = sdTorus(q - float3(0.0, 0.83, 0.0), float2(0.83, 0.06));
    float pot = min(body, lip);
    if (pot < res.x) res = float2(pot, 1.0);

    // Soil: short cylinder sitting just below the rim.
    float soil = sdCappedCylinder(p - float3(0.0, 0.62, 0.0), 0.06, 0.74);
    if (soil < res.x) res = float2(soil, 2.0);

    return res;
}

static float3 calcNormal(float3 p) {
    float2 e = float2(0.0008, 0.0);
    float d = mapScene(p).x;
    float3 n = float3(
        mapScene(p + e.xyy).x - d,
        mapScene(p + e.yxy).x - d,
        mapScene(p + e.yyx).x - d);
    return normalize(n + 1e-6);
}

// Soft shadow via penumbra marching toward the light.
static float softShadow(float3 ro, float3 rd, float mint, float maxt, float k) {
    float res = 1.0;
    float t = mint;
    for (int i = 0; i < 48; i++) {
        if (t >= maxt) break;
        float h = mapScene(ro + rd * t).x;
        if (h < 0.001) return 0.0;
        res = min(res, k * h / max(t, 1e-4));
        t += clamp(h, 0.01, 0.2);
    }
    return clamp(res, 0.0, 1.0);
}

// Ambient occlusion by sampling the field along the normal.
static float calcAO(float3 p, float3 n) {
    float occ = 0.0;
    float sca = 1.0;
    for (int i = 0; i < 5; i++) {
        float hr = 0.01 + 0.12 * float(i) / 4.0;
        float dd = mapScene(p + n * hr).x;
        occ += (hr - dd) * sca;
        sca *= 0.7;
    }
    return clamp(1.0 - 2.5 * occ, 0.0, 1.0);
}

/// Raymarches a procedural terracotta plant pot with soil, soft shadows and AO.
/// The terracotta texture is now a CLEAN, fine ceramic grain rather than dirt:
/// low contrast on the fbm stack (weighted toward the smooth low/mid bands),
/// gentle ±6-8% albedo drift, a faint warm oxide tonal shift instead of dark
/// streaks, and a light matte-tooth normal perturbation. Reads no textures;
/// writes the lit, tonemapped color into `image`.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (2.0 * float2(gid) - res) / res.y;
    uv.y = -uv.y; // Y=0 at top -> world up

    // Orbiting camera.
    float ang = uniforms.time * 0.3 + 0.6;
    float3 ro = float3(3.2 * sin(ang), 1.4, 3.2 * cos(ang));
    float3 ta = float3(0.0, 0.05, 0.0);
    float3 ww = normalize(ta - ro);
    float3 uu = normalize(cross(ww, float3(0.0, 1.0, 0.0)));
    float3 vv = cross(uu, ww);
    float3 rd = normalize(uv.x * uu + uv.y * vv + 1.6 * ww);

    // March.
    float t = 0.0;
    float matId = -1.0;
    for (int i = 0; i < 96; i++) {
        float3 p = ro + rd * t;
        float2 h = mapScene(p);
        if (h.x < 0.0008) { matId = h.y; break; }
        t += h.x;
        if (t > 30.0) break;
    }

    float3 col = float3(0.55, 0.65, 0.78); // sky
    col = mix(col, float3(0.35, 0.42, 0.55), clamp(rd.y * 1.5 + 0.3, 0.0, 1.0));

    if (matId >= 0.0) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p);

        // Material albedo.
        float3 albedo;
        if (matId < 0.5)      albedo = float3(0.45, 0.45, 0.47);      // ground
        else if (matId < 1.5) albedo = float3(0.72, 0.34, 0.22);      // terracotta
        else                  albedo = float3(0.12, 0.09, 0.06);      // soil

        // --- Subtle clay grain, terracotta only -----------------------------
        if (matId > 0.5 && matId < 1.5) {
            // Multi-scale grain in object space (locks to the pot as it spins).
            float grainLo = fbm3D(p * 6.0);
            float grainMid = fbm3D(p * 12.0 + 5.0);
            float speckle  = fbm3D(p * 23.0 + 11.0);
            // Lean on the smooth low/mid bands; keep contrast low so it reads as
            // even ceramic, not scattered dirt specks.
            float tex = grainLo * 0.55 + grainMid * 0.35 + speckle * 0.10;
            tex = clamp((tex - 0.5) * 1.1 + 0.5, 0.0, 1.0);
            tex = smoothstep(0.0, 1.0, tex);

            // Gentle albedo variation (~±7%) with a faint warm oxide drift.
            float f = mix(0.93, 1.07, tex);
            float streak = smoothstep(0.6, 0.35, grainLo); // soft tonal patches
            float3 oxide = float3(0.70, 0.34, 0.23);       // close to base, slightly warmer
            albedo = mix(albedo, oxide, 0.12 * streak);
            albedo *= float3(f, f * 0.97 + 0.01, f * 0.95 + 0.01);

            // Light matte tooth: faint normal breakup spanning two scales.
            float2 e = float2(0.012, 0.0);
            float3 g = float3(
                fbm3D((p + e.xyy) * 23.0 + 11.0) - speckle,
                fbm3D((p + e.yxy) * 23.0 + 11.0) - speckle,
                fbm3D((p + e.yyx) * 23.0 + 11.0) - speckle);
            float3 g2 = float3(
                fbm3D((p + e.xyy) * 9.0) - grainLo,
                fbm3D((p + e.yxy) * 9.0) - grainLo,
                fbm3D((p + e.yyx) * 9.0) - grainLo);
            n = normalize(n + g * 0.03 + g2 * 0.02);
        }

        // Lighting.
        float3 lig = normalize(float3(0.7, 0.9, 0.4));
        float3 hal = normalize(lig - rd);
        float dif = clamp(dot(n, lig), 0.0, 1.0);
        float sh = softShadow(p + n * 0.01, lig, 0.02, 12.0, 12.0);
        dif *= sh;
        float spe = pow(clamp(dot(n, hal), 0.0, 1.0), 32.0) * (matId > 0.5 && matId < 1.5 ? 0.4 : 0.1);
        float ao = calcAO(p, n);
        float amb = 0.4 + 0.6 * clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
        float3 sky = float3(0.5, 0.6, 0.75);

        float3 lin = float3(0.0);
        lin += dif * float3(1.1, 1.0, 0.85);
        lin += amb * sky * ao;
        col = albedo * lin;
        col += spe * float3(1.0, 0.95, 0.85) * sh;

        // Distance fog.
        col = mix(col, float3(0.4, 0.47, 0.6), 1.0 - exp(-0.012 * t * t));
    }

    // Vignette.
    float2 vn = (float2(gid) / res) - 0.5;
    col *= 1.0 - 0.3 * dot(vn, vn);

    // ACES-ish tonemap + gamma.
    col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
    col = pow(clamp(col, 0.0, 1.0), float3(1.0 / 2.2));

    uniforms.textures.image.write(float4(col, 1.0), gid);
}
