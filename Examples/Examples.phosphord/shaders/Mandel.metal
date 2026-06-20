/* phosphor:environment
output = "image"

[[textures]]
id = "image"
format = "rgba16Float"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// Renders an animated Mandelbrot fractal with smooth coloring.
/// Zooms into a visually interesting region over time. Purely procedural.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) - 0.5 * res) / min(res.x, res.y);

    // Animated zoom into an interesting region.
    float t = uniforms.time * 0.15;
    float zoom = pow(1.5, t);
    float2 center = float2(-0.745, 0.186);

    float2 c = center + uv / zoom;
    float2 z = float2(0.0);

    float iter = 0.0;
    const float maxIter = 64.0;

    for (float i = 0.0; i < maxIter; i += 1.0) {
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        if (dot(z, z) > 4.0) {
            iter = i;
            break;
        }
        iter = i;
    }

    float3 col = float3(0.0);
    if (iter < maxIter - 1.0) {
        float sl = iter - log2(log2(dot(z, z))) + 4.0;
        sl = sl / maxIter;
        col.r = 0.5 + 0.5 * sin(3.0 + sl * 15.0 + uniforms.time * 0.5);
        col.g = 0.5 + 0.5 * sin(3.5 + sl * 15.0 + uniforms.time * 0.3);
        col.b = 0.5 + 0.5 * sin(4.0 + sl * 15.0 + uniforms.time * 0.7);
        col = pow(col, float3(0.8));
    }

    uniforms.textures.image.write(float4(col, 1.0), gid);
}
