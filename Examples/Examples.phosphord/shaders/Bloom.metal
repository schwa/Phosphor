/* phosphor:environment
output = "image"

[[textures]]
id = "bufA"
format = "rgba16Float"
swap = "endOfFrame"

[[textures]]
id = "image"

[[passes]]
id = "bufA"
textures = [
    { id = "bufA", access = "write" },
    { id = "bufA", access = "read", name = "feedback" },
]

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
    { id = "bufA", access = "read" },
]

[[uniforms]]
default = 4.0
kind = "float"
name = "blurRadius"
ui = { slider = { max = 16.0, min = 0.0 } }

[[uniforms]]
default = 0.97
kind = "float"
name = "decay"
ui = { slider = { max = 0.999, min = 0.85 } }

[[uniforms]]
default = 0.05
kind = "float"
name = "dotFalloff"
ui = { slider = { max = 0.5, min = 0.01 } }
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// Pass 1: bufA - moving dot + decaying trail (ping-pong feedback).
kernel void bufA(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid);
    float2 center = uniforms.resolution * 0.5;
    float2 offset = float2(cos(uniforms.time * 0.7), sin(uniforms.time)) * uniforms.resolution.y * 0.3;
    float2 dotCenter = center + offset;
    float dist = length(uv - dotCenter);

    float4 previous = uniforms.textures.feedback.read(gid);
    float4 faded = previous * userUniforms.decay;

    float intensity = exp(-dist * userUniforms.dotFalloff);
    float3 color = float3(intensity * 1.5, intensity, intensity * 0.5);

    float4 result = faded + float4(color, 0.0);
    result.a = 1.0;
    uniforms.textures.bufA.write(result, gid);
}

/// Pass 2: image - box-blur bufA into the screen.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    int radius = int(userUniforms.blurRadius);
    int2 size = int2(int(uniforms.resolution.x), int(uniforms.resolution.y));
    int2 coord = int2(gid);
    float4 sum = float4(0);
    int count = 0;
    for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
            int2 sampleCoord = clamp(coord + int2(dx, dy), int2(0), size - 1);
            sum += uniforms.textures.bufA.read(uint2(sampleCoord));
            count += 1;
        }
    }
    float4 blurred = sum / float(count);
    blurred.a = 1.0;
    uniforms.textures.image.write(blurred, gid);
}
