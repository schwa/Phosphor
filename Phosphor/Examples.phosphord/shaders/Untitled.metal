/* prompt: make me a star wars inspired shader */

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
name = "speed"
ui = { slider = { max = 4.0, min = 0.0 } }
*/

uint2 gid [[thread_position_in_grid]];

// Hash helpers for procedural star placement
float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Renders a Star Wars style hyperspace starfield: streaking stars
/// radiating from the screen center, plus a deep-space color wash.
/// Procedural only — writes the final image.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) - 0.5 * res) / res.y;

    float t = uniforms.time * userUniforms.speed;

    // polar coordinates centered on screen
    float r = length(uv) + 1e-4;
    float a = atan2(uv.y, uv.x);

    float3 col = float3(0.0);

    // background deep-space tint
    col += float3(0.01, 0.012, 0.03);

    // Several layers of radial star streaks
    const int LAYERS = 4;
    for (int L = 0; L < LAYERS; L++) {
        float fl = float(L);
        // angular slices form the "spokes" of stars
        float slices = 90.0 + fl * 40.0;
        float seg = floor((a / 6.28318 + 0.5) * slices);
        float seedBase = seg + fl * 137.0;

        // each streak has its own random radial offset/depth
        float rnd = hash11(seedBase);
        // depth travels outward and wraps -> the warp motion
        float depth = fract(rnd + t * (0.3 + 0.5 * hash11(seedBase + 7.0)));
        float starR = depth;                 // radius along the ray

        // distance from this fragment's ray to the star center
        float angCenter = (seg + 0.5) / slices - 0.5;
        angCenter *= 6.28318;
        float da = a - angCenter;
        da = atan2(sin(da), cos(da));        // wrap to [-pi,pi]

        float angWidth = 0.5 / slices;
        float radialDist = abs(r - starR);

        // streak: long in radius, thin in angle, stretches as it nears edge
        float stretch = 0.04 + depth * 0.25;
        float streak = exp(-radialDist * radialDist / (stretch * stretch));
        streak *= exp(-(da * da) / (angWidth * angWidth));

        // fade in from center, brighten outward
        float bright = smoothstep(0.0, 0.2, depth) * (0.4 + depth);

        // bluish-white hyperspace color
        float3 starCol = mix(float3(0.6, 0.75, 1.0), float3(1.0), depth);
        col += starCol * streak * bright * 1.4;
    }

    // central glowing core of the jump
    float core = exp(-r * r * 12.0);
    col += float3(0.5, 0.7, 1.0) * core * 1.2;

    // subtle vignette
    col *= 1.0 - 0.4 * smoothstep(0.6, 1.4, r);

    col = pow(clamp(col, 0.0, 1.0), float3(0.85));
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
