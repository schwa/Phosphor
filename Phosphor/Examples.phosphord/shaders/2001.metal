/* prompt: make a 2001 space oddesy split scan shader */

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
ui = { slider = { max = 5.0, min = 0.0 } }

[[uniforms]]
default = [ 0.7, 0.85, 1.0, 1.0 ]
kind = "color"
name = "tint"
ui = "color"
*/

/// 2001: A Space Odyssey "Stargate" slit-scan corridor. Two mirrored halves
/// (top/bottom) of a flowing band of colored streaks rush toward a central
/// vanishing line, evoking Douglas Trumbull's slit-scan photography.
/// Single procedural pass writing to `image`. Reads no textures.

uint2 gid [[thread_position_in_grid]];

// Hash helpers for pseudo-random streak placement.
float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

// Smooth value noise in 1D.
float vnoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float a = hash11(i);
    float b = hash11(i + 1.0);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u);
}

// Psychedelic palette (Stargate corridor colors).
float3 palette(float t) {
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.33, 0.67);
    return a + b * cos(6.2831853 * (c * t + d));
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    // Centered coords, y in roughly [-1,1].
    float2 uv = (float2(gid) - 0.5 * res) / res.y;

    float t = uniforms.time * userUniforms.speed;

    // The slit-scan effect: vertical distance from the central horizon line
    // drives a perspective "depth". Streaks rush outward from the center line.
    float ay = abs(uv.y);
    // Perspective depth: things near the horizon (ay->0) are far away & fast.
    float depth = 1.0 / (ay + 0.04);

    // Horizontal position warps with depth to create the converging corridor.
    float x = uv.x * depth * 0.35;

    // Scrolling coordinate: streaks rush toward the viewer (out from center).
    float scroll = depth * 0.5 - t * 2.5;

    float3 col = float3(0.0);

    // Several layered bands of color streaks.
    const int BANDS = 5;
    for (int b = 0; b < BANDS; b++) {
        float fb = float(b);
        float bandPhase = fb * 1.7;

        // Horizontal streak pattern: many thin vertical-ish slits.
        float freq = 14.0 + fb * 9.0;
        float n = vnoise(x * freq + bandPhase * 3.1)
                + 0.5 * vnoise(x * freq * 2.3 - bandPhase);

        // Animated flicker along depth.
        float streak = vnoise(scroll * (1.0 + fb * 0.4) + n * 4.0 + bandPhase);
        streak = pow(streak, 3.0);

        // Color from palette, shifting with depth and time.
        float3 c = palette(0.15 * fb + 0.05 * depth + 0.08 * t + n * 0.2);

        // Brightness falls off toward the horizon and at edges.
        float fade = smoothstep(0.0, 0.15, ay) * smoothstep(1.4, 0.2, ay);
        col += c * streak * fade * (0.6 + 0.4 * hash11(fb + 3.0));
    }

    // Bright searing horizon line where the two halves meet.
    float horizon = smoothstep(0.06, 0.0, ay);
    col += float3(1.0, 0.95, 0.8) * horizon * 1.5;

    // Mirror seam glow / vignette.
    float vign = smoothstep(1.6, 0.3, length(uv));
    col *= vign;

    // Apply user tint.
    col *= userUniforms.tint.rgb;

    col = clamp(col, 0.0, 1.0);
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
