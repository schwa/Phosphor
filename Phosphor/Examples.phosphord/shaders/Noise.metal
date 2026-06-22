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

// Hash-based salt-and-pepper noise, animated by frame.
static inline uint wangHash(uint x) {
    x = (x ^ 61u) ^ (x >> 16);
    x *= 9u;
    x ^= x >> 4;
    x *= 0x27d4eb2du;
    x ^= x >> 15;
    return x;
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    uint frameSeed = uint(uniforms.frame);
    uint seed = wangHash(gid.x * 1973u + gid.y * 9277u + frameSeed * 26699u);
    float r = float(seed & 0xffu) / 255.0;
    float v = r < 0.35 ? 1.0 : 0.0;
    uniforms.textures.image.write(float4(v, v, v, 1.0), gid);
}
