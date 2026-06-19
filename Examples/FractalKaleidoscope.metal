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


// Ported from Phosphor 1's example library. mainImage is the legacy entry
// point; the kernel below wraps it with Phosphor 2's canonical signature.
// Fractal kaleidoscope pattern
// Creates beautiful kaleidoscopic patterns through iterative transformations

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float2 r = resolution;
    float2 p = (position.xy * 2.0 - r) / min(r.x, r.y) - mouse;
    
    for(int i = 0; i < 8; ++i) {
        p.xy = abs(p) / dot(p, p) - float2(0.9 + cos(time * 0.2) * 0.4);
    }
    
    return float4(p.x, p.x, p.y, 1.0);
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float4 color = mainImage(float2(gid), uniforms.resolution, uniforms.mouse,
                             uniforms.time, uniforms.frame);
    color.a = 1.0;
    uniforms.textures.image.write(color, gid);
}
