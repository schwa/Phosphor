/* prompt: make it blue */
/* prompt: make a pacman inspired shader */

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

/// Renders a Pac-Man scene: a chomping yellow Pac-Man moving across a black
/// background, eating a row of pellets, with a chasing ghost. Writes `image`.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) - 0.5 * res) / res.y; // centered, y in [-0.5,0.5]
    uv.y = -uv.y; // flip so +y is up

    float t = uniforms.time;
    float3 col = float3(0.0); // black maze background

    // --- Pellet row ---
    float pelletY = 0.0;
    float spacing = 0.12;
    // Pac-Man horizontal motion, wraps across the screen
    float pacX = fract(t * 0.12) * 1.6 - 0.8;

    // Draw pellets, but hide ones Pac-Man has passed (eaten)
    for (int i = -6; i <= 6; i++) {
        float px = float(i) * spacing;
        if (px < pacX - 0.02) continue; // eaten
        float d = length(uv - float2(px, pelletY));
        float pellet = smoothstep(0.018, 0.012, d);
        col += float3(1.0, 0.85, 0.6) * pellet;
    }

    // --- Pac-Man ---
    float2 p = uv - float2(pacX, pelletY);
    float r = length(p);
    float ang = atan2(p.y, p.x);
    // Mouth open/close
    float mouth = 0.5 * (0.5 + 0.5 * sin(t * 10.0)); // 0..0.5 rad
    float body = smoothstep(0.085, 0.08, r);
    // Carve out mouth wedge facing +x (direction of travel)
    float inMouth = step(fabs(ang), mouth);
    float pac = body * (1.0 - inMouth);
    col = mix(col, float3(1.0, 0.9, 0.05), pac);

    // --- Ghost (chasing behind) ---
    float2 g = uv - float2(pacX - 0.28, pelletY);
    // body: circle top + box bottom
    float2 gb = g;
    float ghostBody = 0.0;
    if (gb.y >= 0.0) {
        ghostBody = smoothstep(0.085, 0.08, length(gb));
    } else {
        // rectangular skirt with wavy bottom
        float wave = 0.012 * sin(gb.x * 80.0 + t * 6.0);
        float box = step(fabs(gb.x), 0.08) * step(-0.085 - wave, gb.y);
        ghostBody = box;
    }
    float3 ghostCol = float3(1.0, 0.2, 0.2); // Blinky red
    col = mix(col, ghostCol, clamp(ghostBody, 0.0, 1.0));

    // Ghost eyes
    float2 e1 = g - float2(-0.028, 0.02);
    float2 e2 = g - float2( 0.028, 0.02);
    float eye = smoothstep(0.022, 0.018, length(e1)) +
                smoothstep(0.022, 0.018, length(e2));
    col = mix(col, float3(1.0), clamp(eye, 0.0, 1.0));
    float2 pu1 = g - float2(-0.020, 0.018);
    float2 pu2 = g - float2( 0.036, 0.018);
    float pupil = smoothstep(0.011, 0.008, length(pu1)) +
                  smoothstep(0.011, 0.008, length(pu2));
    col = mix(col, float3(0.1, 0.1, 0.6), clamp(pupil, 0.0, 1.0));

    col = clamp(col, 0.0, 1.0);
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
