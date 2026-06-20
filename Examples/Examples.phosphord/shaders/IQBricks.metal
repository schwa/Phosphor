/* phosphor:environment
flipY = true
output = "image"

[[uniforms]]
default = 0.35
kind = "float"
name = "stepScale"
ui = { slider = { max = 1.0, min = 0.1 } }

[[uniforms]]
default = 0.0025
kind = "float"
name = "normalEps"
ui = { slider = { max = 0.02, min = 0.0005 } }

[[uniforms]]
default = 0.07
kind = "float"
name = "noiseAmount"
ui = { slider = { max = 0.2, min = 0.0 } }

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

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

// Ported from Inigo Quilez (https://iquilezles.org/) - educational use only.
// Improv session brick-cylinder raymarcher.

#define AA 1

static inline float2 cylIntersect(float3 ro, float3 rd, float rad) {
    float a = dot(rd.xz, rd.xz);
    float b = dot(ro.xz, rd.xz);
    float c = dot(ro.xz, ro.xz) - rad * rad;
    float h = b * b - a * c;
    if (h < 0.0) { return float2(-1.0); }
    h = sqrt(h);
    return float2(-b - h, -b + h) / a;
}

static inline float sdBox3(float3 p, float3 b) {
    float3 q = abs(p) - b;
    float g = max(q.x, max(q.y, q.z));
    return g < 0.0 ? g : length(max(q, 0.0));
}

static inline float sdBox2(float2 p, float2 b) {
    float2 q = abs(p) - b;
    float g = max(q.x, q.y);
    return g < 0.0 ? g : length(max(q, 0.0));
}

static inline float sdTube(float3 p, float r, float h, float w) {
    float2 q = float2(length(p.xz) - r, p.y);
    return sdBox2(q, float2(w, h));
}

static inline float2 smin2(float a, float b, float k) {
    k *= 4.0;
    float h = max(k - abs(a - b), 0.0) / k;
    return float2(min(a, b) - h * h * k / 4.0,
                  a < b ? h * 0.5 : 1.0 - h * 0.5);
}

static inline float hash3(float3 p) {
    p += 1000.0;
    return fract(123.0 * sin(p.x * 21.6) * sin(p.y * 43.4) * sin(p.z * 14.5));
}

static inline float cnoise(float3 p) {
    float3 ip = floor(p);
    float3 fp = fract(p);
    fp = fp * fp * (3.0 - 2.0 * fp);

    float a = hash3(ip + float3(0, 0, 0));
    float b = hash3(ip + float3(1, 0, 0));
    float c = hash3(ip + float3(0, 1, 0));
    float d = hash3(ip + float3(1, 1, 0));
    float e = hash3(ip + float3(0, 0, 1));
    float f = hash3(ip + float3(1, 0, 1));
    float g = hash3(ip + float3(0, 1, 1));
    float hv = hash3(ip + float3(1, 1, 1));

    return mix(mix(mix(a, b, fp.x), mix(c, d, fp.x), fp.y),
               mix(mix(e, f, fp.x), mix(g, hv, fp.x), fp.y),
               fp.z);
}

static inline float fbm(float3 p) {
    float f = 0.0;
    float a = 0.5;
    for (int i = 0; i < 6; i++) {
        f += a * cnoise(p);
        p = p.yxz * 1.99 + 0.1;
        a *= 0.56;
    }
    return f;
}

/// Builds a 2D rotation matrix. GLSL would write
/// `mat2(cos, -sin, sin, cos)` which is column-major; MSL is the same.
static inline float2x2 rot2(float an) {
    float c = cos(an);
    float s = sin(an);
    // GLSL mat2(c, -s, s, c) is column-major: col0=(c,-s), col1=(s,c).
    return float2x2(c, -s, s, c);
}

static inline float4 mapScene(float3 p, float time, float noiseAmount) {
    {
        float an = 6.2831 * time / 40.0;
        p.xz = rot2(an) * p.xz;
    }

    float3 op = p;

    float sp = 0.40;
    float layerID = clamp(round(p.y / sp), -10.0, 1.0);
    p.y = p.y - sp * layerID;

    {
        float rb = 123.0 * sin(layerID * 1.3);
        p.xz = rot2(rb) * p.xz;
    }

    float an = 6.283185 / 12.0;
    float a = atan2(p.z, p.x);
    float sectorID = round(a / an);
    float ra = sectorID * an;
    p.xz = rot2(ra) * p.xz;

    float h1 = sin(ra * 123.0 + layerID * 924.0);
    float h2 = sin(ra * 462.0 + layerID * 214.9);
    float h3 = sin(ra * 754.0 + layerID * 534.2);
    float h4 = sin(ra * 445.0 + layerID * 736.6);

    p.x -= 1.5 + 0.05 * abs(h1);
    float d1 = sdBox3(p, float3(0.05, 0.12 + 0.05 * h3, 0.3 + 0.10 * h2)) - 0.1;

    float f = fbm(op / 0.15);
    d1 += noiseAmount * f;

    float d2 = sdTube(op - float3(0.0, -1.0, 0.0), 1.45, 1.5, 0.15);
    d2 += 0.02 * f;

    float2 re = smin2(d1, d2, 0.01);
    return float4(re.x, re.y, h4, 0.0);
}

#define ZERO 0

static inline float3 calcNormal(float3 pos, float time, float noiseAmount, float normalEps) {
    float3 n = float3(0.0);
    for (int i = ZERO; i < 4; i++) {
        float3 e = 0.5773 * (2.0 * float3(float((((i + 3) >> 1) & 1)),
                                          float(((i >> 1) & 1)),
                                          float((i & 1))) - 1.0);
        n += e * mapScene(pos + normalEps * e, time, noiseAmount).x;
    }
    return normalize(n);
}

static inline float calcAO(float3 pos, float3 nor, float time, float noiseAmount) {
    float occ = 0.0;
    float sca = 1.0;
    for (int i = 0; i < 8; i++) {
        float h = 0.005 + 0.2 * float(i) / 8.0;
        float3 dir = normalize(nor + 0.85 * sin(h * 31.31 + float3(0, 2, 4)));
        dir *= sign(dot(dir, nor));
        float d = mapScene(pos + h * dir, time, noiseAmount).x;
        occ += max(h - d, 0.0) * sca;
        sca *= 0.95;
        if (occ > 1.0 / 1.5) { break; }
    }
    return clamp(1.0 - 1.5 * occ, 0.0, 1.0);
}

static inline float calcSoftshadow(float3 ro, float3 rd, float k, float time, float noiseAmount) {
    float res = 1.0;
    float tmax = cylIntersect(ro, rd, 1.75).y;
    float t = 0.001;
    for (int i = 0; i < 128; i++) {
        float h = mapScene(ro + rd * t, time, noiseAmount).x;
        res = min(res, k * h / t);
        t += clamp(h * 0.5, 0.02, 0.25);
        if (res < 0.01 || t > tmax) { break; }
    }
    return clamp(res, 0.0, 1.0);
}

static inline float4 intersectScene(float3 ro, float3 rd, float time, float noiseAmount, float stepScale) {
    float4 res = float4(-1.0);
    float2 bb = cylIntersect(ro, rd, 1.73);
    if (bb.y > 0.0) {
        float t = max(bb.x, 0.0);
        float tmax = bb.y;
        for (int i = 0; i < 256 && t < tmax; i++) {
            float4 h = mapScene(ro + t * rd, time, noiseAmount);
            if (h.x < 0.002) { res = float4(t, h.yzw); break; }
            t += h.x * stepScale;
        }
    }
    return res;
}

static inline float3x3 setCamera(float3 ro, float3 ta, float cr) {
    float3 cw = normalize(ta - ro);
    float3 cp = float3(sin(cr), cos(cr), 0.0);
    float3 cu = normalize(cross(cw, cp));
    float3 cv = cross(cu, cw);
    return float3x3(cu, cv, cw);
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 fragCoord = float2(gid) + 0.5;
    float2 iResolution = uniforms.resolution;
    float time = uniforms.time;
    float stepScale = userUniforms.stepScale;
    float normalEps = userUniforms.normalEps;
    float noiseAmount = userUniforms.noiseAmount;

    float3 tot = float3(0.0);

#if AA > 1
    for (int m = 0; m < AA; m++)
    for (int n = 0; n < AA; n++) {
        float2 o = float2(float(m), float(n)) / float(AA) - 0.5;
        float2 p = (2.0 * (fragCoord + o) - iResolution) / iResolution.y;
#else
    {
        float2 p = (2.0 * fragCoord - iResolution) / iResolution.y;
#endif

        float3 ta = float3(0.0, 0.0, 0.0);
        float3 ro = float3(4.0, 1.2, 0.0);

        float3x3 ca = setCamera(ro, ta, 0.0);
        float fl = 2.0;
        float3 rd = ca * normalize(float3(p, fl));

        float3 col = float3(1.0 + rd.y) * 0.03;

        float4 tuvw = intersectScene(ro, rd, time, noiseAmount, stepScale);
        if (tuvw.x > 0.0) {
            float3 pos = ro + tuvw.x * rd;
            float3 nor = calcNormal(pos, time, noiseAmount, normalEps);

            float3 brickColor = float3(0.2, 0.04, 0.02);
            brickColor *= 1.0 + 0.4 * tuvw.z;
            brickColor *= 1.0 + 0.2 * sin(3.1415927 * tuvw.z + float3(0, 2, 4));

            float3 mortarColor = float3(0.2, 0.15, 0.13);
            float3 mate = mix(brickColor, mortarColor, tuvw.y);

            float3 lig = normalize(float3(0.3, 0.4, -0.9));
            float dif = max(0.0, dot(nor, lig));
            float sha = calcSoftshadow(pos + nor * 0.001, lig, 32.0, time, noiseAmount);
            float3 hal = normalize(lig - rd);
            float spe = pow(clamp(dot(nor, hal), 0.0, 1.0), 8.0);
            spe *= dif * sha;
            spe *= 0.04 + 0.96 * pow(clamp(1.0 - dot(hal, lig), 0.0, 1.0), 5.0);

            col = dif * sha * mate * float3(4.0, 2.0, 1.0);
            col += spe * float3(5.0);

            float occ = calcAO(pos, nor, time, noiseAmount) * (1.0 + 0.4 * nor.y);
            col += mate * occ * float3(0.5, 0.7, 1.5) * 1.3;
        }

        col = col * 2.5 / (2.0 + col);
        tot += pow(col, float3(0.45));
    }

#if AA > 1
    tot /= float(AA * AA);
#endif

    tot += sin(fragCoord.x * 114.0) * sin(fragCoord.y * 211.1) / 512.0;

    uniforms.textures.image.write(float4(tot, 1.0), gid);
}
