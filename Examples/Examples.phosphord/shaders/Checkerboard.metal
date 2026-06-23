/* phosphor:environment
output = "image"

[[textures]]
id = "image"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// Animated scrolling checkerboard with subtle color tinting. Procedural.
float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float baseSize = 50.0;
    float checkerSize = baseSize + sin(time * 0.5) * 20.0;
    float2 scrollOffset = float2(time * 10.0, time * 7.0);
    float2 checker = floor((position + scrollOffset) / checkerSize);
    float pattern = fmod(checker.x + checker.y, 2.0);
    float gray = pattern * 0.8 + 0.1;
    float3 animatedColor = float3(
        gray + 0.15 * sin(time * 0.3),
        gray + 0.15 * sin(time * 0.3 + 2.094),
        gray + 0.15 * sin(time * 0.3 + 4.189)
    );
    return float4(animatedColor, 1.0);
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float4 color = mainImage(float2(gid), uniforms.resolution, uniforms.mouse,
                             uniforms.time, uniforms.frame);
    color.a = 1.0;
    uniforms.textures.image.write(color, gid);
}
