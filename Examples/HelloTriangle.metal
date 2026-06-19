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
    float2 ndc = (position * 2.0 - resolution) / min(resolution.x, resolution.y);

    float2 v0 = float2(0.0, 0.866);
    float2 v1 = float2(-1.0, -0.5);
    float2 v2 = float2(1.0, -0.5);

    float2 v0v1 = v1 - v0;
    float2 v0v2 = v2 - v0;
    float2 v0p = ndc - v0;

    float dot00 = dot(v0v2, v0v2);
    float dot01 = dot(v0v2, v0v1);
    float dot02 = dot(v0v2, v0p);
    float dot11 = dot(v0v1, v0v1);
    float dot12 = dot(v0v1, v0p);

    float invDenom = 1.0 / (dot00 * dot11 - dot01 * dot01);
    float u = (dot11 * dot02 - dot01 * dot12) * invDenom;
    float v = (dot00 * dot12 - dot01 * dot02) * invDenom;
    float w = 1.0 - u - v;

    if (u >= 0.0 && v >= 0.0 && w >= 0.0) {
        return float4(w, v, u, 1.0);
    }
    return float4(0.1, 0.1, 0.1, 1.0);
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
