/* phosphor:environment
output = "image"

[[textures]]
id = "bufA"
swap = "endOfFrame"

[[textures]]
id = "image"

[[passes]]
id = "bufA"
textures = [
    { id = "bufA", access = "write" },
]

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
    { id = "bufA", access = "read" },
]
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// bufA: writes a known value based on the frame counter. Red on even 30-frame
/// periods, green on odd.
kernel void bufA(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    uint parity = (uint(uniforms.frame) / 30u) % 2u;
    float4 color = parity == 0u
        ? float4(1.0, 0.0, 0.0, 1.0)
        : float4(0.0, 1.0, 0.0, 1.0);
    uniforms.textures.bufA.write(color, gid);
}

/// image: samples bufA. Left half shows the raw sample; right half is yellow
/// if the sample matches this frame's expected value (correct parity routing)
/// or blue if it doesn't.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float4 sampled = uniforms.textures.bufA.read(gid);
    uint parity = (uint(uniforms.frame) / 30u) % 2u;
    float4 expected = parity == 0u
        ? float4(1.0, 0.0, 0.0, 1.0)
        : float4(0.0, 1.0, 0.0, 1.0);
    bool matches = (sampled.r == expected.r) && (sampled.g == expected.g);
    if (gid.x < uint(uniforms.resolution.x) / 2u) {
        uniforms.textures.image.write(sampled, gid);
    } else {
        float4 verdict = matches
            ? float4(1.0, 1.0, 0.0, 1.0)
            : float4(0.0, 0.0, 1.0, 1.0);
        uniforms.textures.image.write(verdict, gid);
    }
}
