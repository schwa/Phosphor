/* prompt: make a SDF rendered sphere. use nice shading on it */
/* prompt: add a SDF cube and use the operator on them to make them merge */
/* prompt: move the two shapes a little futher apart - add a camera distance slider */
/* prompt: Can we give each shape a unique color? */

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
default = 5.0
kind = "float"
name = "cameraDistance"
ui = { slider = { max = 12.0, min = 2.0 } }
*/

uint2 gid [[thread_position_in_grid]];

/// Signed distance to a sphere of given radius centered at origin.
float sdSphere(float3 p, float r) {
    return length(p) - r;
}

/// Signed distance to a box with the given half-extents.
float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

/// Polynomial smooth minimum: blends two distances with smoothing radius k.
float smoothUnion(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// Distance to the sphere only (used for distance and for color blending).
float sphereSDF(float3 p) {
    return sdSphere(p - float3(-1.1, 0.0, 0.0), 0.9);
}

/// Distance to the rotating cube only.
float cubeSDF(float3 p, float time) {
    float3 pc = p - float3(1.1, 0.0, 0.0);
    pc = rotate3D(time * 0.6, normalize(float3(0.2, 1.0, 0.3))) * pc;
    return sdBox(pc, float3(0.7));
}

/// Scene SDF: a sphere smoothly merged with a rotating cube.
float sceneSDF(float3 p, float time) {
    float sphere = sphereSDF(p);
    float cube   = cubeSDF(p, time);
    float wobble = 0.6 + 0.25 * sin(time);
    return smoothUnion(sphere, cube, wobble);
}

/// Returns a base color for point p by blending each shape's unique color
/// based on how close p is to each shape. Sphere = orange, cube = teal/blue.
float3 sceneColor(float3 p, float time) {
    float dSphere = sphereSDF(p);
    float dCube   = cubeSDF(p, time);
    float wobble  = 0.6 + 0.25 * sin(time);

    // Same blend weight used by smoothUnion, so the seam color matches the
    // smooth-union geometry seam.
    float h = clamp(0.5 + 0.5 * (dCube - dSphere) / wobble, 0.0, 1.0);

    float3 sphereColor = float3(0.85, 0.35, 0.25); // warm orange
    float3 cubeColor   = float3(0.20, 0.55, 0.85); // cool teal/blue
    return mix(cubeColor, sphereColor, h);
}

/// Estimate the surface normal via central differences on the SDF.
float3 calcNormal(float3 p, float time) {
    float2 e = float2(0.001, 0.0);
    return normalize(float3(
        sceneSDF(p + e.xyy, time) - sceneSDF(p - e.xyy, time),
        sceneSDF(p + e.yxy, time) - sceneSDF(p - e.yxy, time),
        sceneSDF(p + e.yyx, time) - sceneSDF(p - e.yyx, time)));
}

/// Raymarches a sphere + cube smooth-union SDF and shades it with a simple
/// Blinn-Phong model. Each shape now has its own base color, blended across the
/// merge seam. The camera distance is driven by `cameraDistance`. Writes `image`.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float time = uniforms.time;
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) * 2.0 - res) / res.y;

    // Camera setup (distance controlled by slider)
    float3 ro = float3(0.0, 0.0, userUniforms.cameraDistance);
    float3 rd = normalize(float3(uv, -1.8));

    // Background gradient
    float3 bg = mix(float3(0.05, 0.06, 0.10),
                    float3(0.15, 0.17, 0.25),
                    0.5 + 0.5 * uv.y);
    float3 col = bg;

    // Raymarch
    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 80; i++) {
        float3 p = ro + rd * t;
        float d = sceneSDF(p, time);
        if (d < 0.001) { hit = true; break; }
        t += d;
        if (t > 40.0) break;
    }

    if (hit) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p, time);

        // Rotating light
        float3 lightDir = normalize(float3(
            cos(time) * 1.2,
            0.8,
            sin(time) * 1.2));

        float3 viewDir = normalize(ro - p);
        float3 halfDir = normalize(lightDir + viewDir);

        float diff = max(dot(n, lightDir), 0.0);
        float spec = pow(max(dot(n, halfDir), 0.0), 48.0);
        float rim  = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0);

        // Per-shape base color blended at the merge seam.
        float3 baseColor = sceneColor(p, time);
        float3 ambient = baseColor * 0.18;

        float3 shaded = ambient
            + baseColor * diff * 0.9
            + float3(1.0) * spec * 0.8
            + float3(0.3, 0.5, 0.9) * rim * 0.6;

        col = shaded;
    }

    // Gamma-ish tonemap
    col = col / (1.0 + col);
    col = pow(clamp(col, 0.0, 1.0), float3(0.4545));

    uniforms.textures.image.write(float4(col, 1.0), gid);
}
