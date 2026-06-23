/* phosphor:environment
output = "image"

[[textures]]
id = "image"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]

[[uniforms]]
name = "frequency"
kind = "float"
default = 6.0
ui = { slider = { min = 0.5, max = 24.0 } }

[[uniforms]]
name = "contrast"
kind = "float"
default = 1.5
ui = { slider = { min = 0.5, max = 4.0 } }

[[uniforms]]
name = "tint"
kind = "color"
default = [0.6, 0.8, 1.0, 1.0]
ui = "color"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// Classic procedural plasma: a sum of four sin waves over uv + length(uv),
/// raised to a contrast power and tinted by a user color. Pure procedural,
/// no inputs.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    uv = uv * 2.0 - 1.0;
    uv.x *= uniforms.resolution.x / uniforms.resolution.y;

    float freq = userUniforms.frequency;
    float t = uniforms.time;

    float v = sin(uv.x * freq + t);
    v += sin(uv.y * freq + t * 1.3);
    v += sin((uv.x + uv.y) * freq * 0.5 + t * 0.7);
    v += sin(length(uv) * freq * 2.0 - t * 1.7);

    v = v * 0.25 + 0.5;
    v = pow(v, userUniforms.contrast);

    float3 base = float3(v);
    float3 tinted = base * userUniforms.tint.rgb;
    uniforms.textures.image.write(float4(tinted, 1.0), gid);
}
