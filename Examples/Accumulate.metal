/* phosphor:environment
output = "image"

[[textures]]
id = "image"
swap = "endOfFrame"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
    { id = "image", access = "read", name = "feedback" },
]
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// Ping-pong accumulator with horizontal shift. Demonstrates spatial feedback:
/// each frame reads the previous frame one column to the left and fades it.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    uint2 sampleCoord = uint2(gid.x > 0u ? gid.x - 1u : gid.x, gid.y);
    float4 shifted = uniforms.textures.feedback.read(sampleCoord) * 0.99;
    float4 result = shifted;
    if (gid.x < 4u && gid.y < 20u) {
        result = float4(1, 1, 1, 1);
    }
    result.a = 1.0;
    uniforms.textures.image.write(result, gid);
}
