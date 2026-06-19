/* phosphor:environment
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
inputs = [ { name = "iChannel0", resource = "image" } ]
output = "image"

[[resources]]
id = "image"
kind = "texture2D"
spec = { flipTiming = "endOfFrame", format = "rgba32Float", initial = "zero", pingPong = true, size = "drawable" }*/

#include "Phosphor.h"

// Ping-pong accumulator with horizontal shift. Demonstrates spatial feedback.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    uint2 sampleCoord = uint2(gid.x > 0u ? gid.x - 1u : gid.x, gid.y);
    float4 shifted = channels.iChannel0.read(sampleCoord) * 0.99;
    float4 result = shifted;
    if (gid.x < 4u && gid.y < 20u) {
        result = float4(1, 1, 1, 1);
    }
    result.a = 1.0;
    outTexture.write(result, gid);
}
