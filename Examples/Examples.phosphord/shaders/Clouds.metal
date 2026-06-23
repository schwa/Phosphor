/* prompt: Volumetric clouds please! */
/* prompt: add a camera rotation slider */
/* prompt: and vertical slider too */
/* prompt: add a sun toggle */

/* phosphor:environment
flipY = true
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
default = 0.5
kind = "float"
name = "coverage"
ui = { slider = { max = 0.9, min = 0.1 } }

[[uniforms]]
default = 0.3
kind = "float"
name = "speed"
ui = { slider = { max = 2.0, min = 0.0 } }

[[uniforms]]
default = 0.0
kind = "float"
name = "cameraRotation"
ui = { slider = { max = 3.14159, min = -3.14159 } }

[[uniforms]]
default = 0.0
kind = "float"
name = "cameraPitch"
ui = { slider = { max = 1.0, min = -1.0 } }

[[uniforms]]
default = true
kind = "bool"
name = "sunEnabled"
ui = "toggle"
*/

/// Single-pass volumetric cloud raymarcher. Marches a ray through a
/// procedural fBm density field lit by a single sun, then composites the
/// accumulated cloud color over a sky gradient. The camera direction is
/// rotated horizontally by `cameraRotation` (yaw) and vertically by
/// `cameraPitch` (pitch). A `sunEnabled` toggle turns the sun glare on/off.
/// Writes the final image to `image`. Reads no textures (fully procedural).

uint2 gid [[thread_position_in_grid]];

float fbm(float3 p) {
    float a = 0.5;
    float v = 0.0;
    for (int i = 0; i < 5; i++) {
        v += a * valueNoise3D(p);
        p *= 2.02;
        a *= 0.5;
    }
    return v;
}

// cloud density: a slab between y in [1,4], shaped by fbm
float density(float3 p, float t, float cover) {
    p.x += t * 0.6; // wind
    float base = fbm(p * 0.4);
    float slab = smoothstep(1.0, 2.0, p.y) * (1.0 - smoothstep(3.0, 4.5, p.y));
    float d = (base - (1.0 - cover)) * slab;
    return clamp(d * 2.5, 0.0, 1.0);
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) * 2.0 - res) / res.y;
    float t = uniforms.time * userUniforms.speed;

    // camera
    float3 ro = float3(0.0, 1.5, -6.0);
    float3 rd = normalize(float3(uv, 1.6));

    // vertical camera rotation (pitch) around the X axis
    float pitch = userUniforms.cameraPitch;
    float pc = cos(pitch);
    float ps = sin(pitch);
    rd = float3(rd.x, rd.y * pc - rd.z * ps, rd.y * ps + rd.z * pc);
    ro = float3(ro.x, ro.y * pc - ro.z * ps, ro.y * ps + ro.z * pc);

    // horizontal camera rotation (yaw) around the Y axis
    float yaw = userUniforms.cameraRotation;
    float cs = cos(yaw);
    float sn = sin(yaw);
    rd = float3(rd.x * cs + rd.z * sn, rd.y, -rd.x * sn + rd.z * cs);
    ro = float3(ro.x * cs + ro.z * sn, ro.y, -ro.x * sn + ro.z * cs);

    float3 sunDir = normalize(float3(0.7, 0.5, 0.4));
    bool sunOn = userUniforms.sunEnabled > 0.5;

    // sky background
    float horizon = smoothstep(-0.2, 0.5, rd.y);
    float3 skyTop = float3(0.25, 0.45, 0.85);
    float3 skyBot = float3(0.7, 0.8, 0.95);
    float3 sky = mix(skyBot, skyTop, horizon);
    if (sunOn) {
        float sun = pow(max(dot(rd, sunDir), 0.0), 64.0);
        sky += float3(1.0, 0.9, 0.7) * sun;
    }

    // raymarch the cloud slab
    float3 col = float3(0.0);
    float transmittance = 1.0;
    float cover = userUniforms.coverage;

    float dist = 2.0;
    for (int i = 0; i < 56; i++) {
        if (transmittance < 0.02) break;
        float3 p = ro + rd * dist;
        if (p.y > 5.0 || dist > 30.0) break;
        float d = density(p, t, cover);
        if (d > 0.001) {
            // light: difference of density toward the sun
            float dl = density(p + sunDir * 0.5, t, cover);
            float light = clamp(d - dl, 0.0, 1.0);
            // when the sun is off, fall back to flat ambient lighting
            float litAmount = sunOn ? light * 2.0 : 0.3;
            float3 lit = mix(float3(0.45, 0.5, 0.6),
                             float3(1.0, 0.95, 0.85), litAmount);
            float a = d * 0.45;
            col += transmittance * a * lit;
            transmittance *= (1.0 - a);
        }
        dist += 0.25 + dist * 0.02;
    }

    float3 outc = sky * transmittance + col;
    outc = pow(clamp(outc, 0.0, 1.0), float3(0.9));
    uniforms.textures.image.write(float4(outc, 1.0), gid);
}
