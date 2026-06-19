/* phosphor:environment
output = "image"

[[passes]]
enabled = true
id = "bufA"
inputs = [ { name = "iChannel0", resource = "bufA" } ]
output = "bufA"

[[passes]]
enabled = true
id = "image"
inputs = [ { name = "iChannel0", resource = "bufA" } ]
output = "image"

[[resources]]
id = "bufA"
kind = "texture2D"
spec = { flipTiming = "endOfFrame", format = "rgba16Float", initial = "zero", pingPong = true, size = "drawable" }

[[resources]]
id = "image"
kind = "texture2D"
spec = { flipTiming = "endOfFrame", format = "rgba32Float", initial = "zero", pingPong = false, size = "drawable" }

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
ui = { slider = { max = 0.5, min = 0.01 } }*/

#include "Phosphor.h"

// Pass 1: bufA — moving dot + trail
kernel void bufA(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 uv = float2(gid);
    float2 center = uniforms->resolution * 0.5;
    float2 offset = float2(cos(uniforms->time * 0.7), sin(uniforms->time)) * uniforms->resolution.y * 0.3;
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
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    int radius = int(userUniforms->blurRadius);
    int2 size = int2(int(uniforms->resolution.x), int(uniforms->resolution.y));
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
