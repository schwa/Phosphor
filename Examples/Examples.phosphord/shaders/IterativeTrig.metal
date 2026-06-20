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

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float4 p = float4(position.xy / 4e2, 0, -4);
    for(int i = 0; i < 9; ++i) {
        p += float4(
            sin(-(p.x + time * 0.2)) + atan(p.y * p.w),
            cos(-p.x) + atan(p.z * p.w),
            cos(-(p.x + sin(time * 0.8))) + atan(p.z * p.w),
            0
        );
    }
    return p;
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
