/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

[[passes]]
id = "image"
output = "image"
*/

#include "Phosphor.h"

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
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    uint frameSeed = uint(uniforms->frame);
    uint seed = wangHash(gid.x * 1973u + gid.y * 9277u + frameSeed * 26699u);
    float r = float(seed & 0xffu) / 255.0;
    float v = r < 0.35 ? 1.0 : 0.0;
    outTexture.write(float4(v, v, v, 1.0), gid);
}
