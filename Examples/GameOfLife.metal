/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba32Float", pingPong = true, flipTiming = "endOfFrame", initial = "zero" }

[[passes]]
id = "image"
output = "image"
inputs = [{ name = "iChannel0", resource = "image" }]
*/

#include "Phosphor.h"

// Tiny integer hash (Wang). Cheap noise for seeding.
static inline uint wangHash(uint x) {
    x = (x ^ 61u) ^ (x >> 16);
    x *= 9u;
    x ^= x >> 4;
    x *= 0x27d4eb2du;
    x ^= x >> 15;
    return x;
}

static inline bool isAlive(texture2d<float, access::read> tex, int2 coord, int2 size) {
    if (coord.x < 0 || coord.x >= size.x || coord.y < 0 || coord.y >= size.y) {
        return false;
    }
    float4 c = tex.read(uint2(coord));
    return c.r > 0.5;
}

kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    int2 size = int2(int(uniforms.resolution.x), int(uniforms.resolution.y));
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) {
        return;
    }

    // Seed on first frame, or whenever the view was just resized.
    if (uniforms.frame < 1.0 || uniforms.resized != 0u) {
        uint seed = wangHash(gid.x * 1973u + gid.y * 9277u + 12345u);
        float r = float(seed & 0xffu) / 255.0;
        float alive = r < 0.35 ? 1.0 : 0.0;
        outTexture.write(float4(alive, alive, alive, 1.0), gid);
        return;
    }

    // Step the Life rule.
    int2 coord = int2(gid);
    int neighbors = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) { continue; }
            if (isAlive(channels.iChannel0, coord + int2(dx, dy), size)) {
                neighbors += 1;
            }
        }
    }
    bool wasAlive = isAlive(channels.iChannel0, coord, size);
    bool nowAlive = wasAlive ? (neighbors == 2 || neighbors == 3) : (neighbors == 3);
    float v = nowAlive ? 1.0 : 0.0;
    outTexture.write(float4(v, v, v, 1.0), gid);
}
