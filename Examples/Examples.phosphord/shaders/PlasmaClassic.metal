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
    float2 uv = position / resolution.xy;
    float plasma = 0.0;

    plasma += sin((uv.x + time * 0.3) * 10.0);
    plasma += sin((uv.y + time * 0.2) * 8.0);
    plasma += sin((uv.x + uv.y + time * 0.25) * 12.0);

    float2 center = float2(0.5, 0.5);
    float dist = length(uv - center);
    plasma += sin((dist - time * 0.4) * 25.0);

    float2 movingCenter = float2(
        0.5 + 0.3 * sin(time * 0.7),
        0.5 + 0.3 * cos(time * 0.9)
    );
    float dist2 = length(uv - movingCenter);
    plasma += sin((dist2 - time * 0.35) * 20.0);

    plasma = plasma / 5.0;
    float3 color = 0.5 + 0.5 * cos(PI * plasma + float3(0.0, 2.0, 4.0) + time * 0.5);
    color = pow(color, float3(0.8));
    return float4(color, 1.0);
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
