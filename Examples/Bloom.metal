/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "bufA"
spec = { size = "drawable", format = "rgba16Float", pingPong = true, flipTiming = "endOfFrame", initial = "zero" }

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

[[passes]]
id = "bufA"
output = "bufA"
inputs = [{ name = "iChannel0", resource = "bufA" }]

[[passes]]
id = "image"
output = "image"
inputs = [{ name = "iChannel0", resource = "bufA" }]

[[uniforms]]
name = "blurRadius"
kind = "float"
default = 4.0
ui = { slider = { min = 0.0, max = 16.0 } }

[[uniforms]]
name = "decay"
kind = "float"
default = 0.97
ui = { slider = { min = 0.85, max = 0.999 } }

[[uniforms]]
name = "dotFalloff"
kind = "float"
default = 0.05
ui = { slider = { min = 0.01, max = 0.5 } }
*/

#include "Phosphor.h"

// Pass 1: bufA — moving dot + trail
kernel void bufA(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 uv = float2(gid);
    float2 center = uniforms.resolution * 0.5;
    float2 offset = float2(cos(uniforms.time * 0.7), sin(uniforms.time)) * uniforms.resolution.y * 0.3;
    float2 dotCenter = center + offset;
    float dist = length(uv - dotCenter);

    float4 previous = channels.iChannel0.read(gid);
    float4 faded = previous * userUniforms->decay;

    // Bright moving dot. Smaller dotFalloff = bigger soft glow.
    float intensity = exp(-dist * userUniforms->dotFalloff);
    float3 color = float3(intensity * 1.5, intensity, intensity * 0.5);

    float4 result = faded + float4(color, 0.0);
    result.a = 1.0;
    outTexture.write(result, gid);
}

// Pass 2: image — blur bufA into the screen
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    int radius = int(userUniforms->blurRadius);
    int2 size = int2(int(uniforms.resolution.x), int(uniforms.resolution.y));
    int2 coord = int2(gid);
    float4 sum = float4(0);
    int count = 0;
    // Cheap box blur over a (2r+1)x(2r+1) window. Fine for r<=16.
    for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
            int2 sampleCoord = clamp(coord + int2(dx, dy), int2(0), size - 1);
            sum += channels.iChannel0.read(uint2(sampleCoord));
            count += 1;
        }
    }
    float4 blurred = sum / float(count);
    blurred.a = 1.0;
    outTexture.write(blurred, gid);
}
