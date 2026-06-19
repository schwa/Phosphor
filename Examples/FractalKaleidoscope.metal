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

// Ported from Phosphor 1's example library. mainImage is the legacy entry
// point; the kernel below wraps it with Phosphor 2's canonical signature.
// Fractal kaleidoscope pattern
// Creates beautiful kaleidoscopic patterns through iterative transformations

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer) {
    float2 r = resolution;
    float2 p = (position.xy * 2.0 - r) / min(r.x, r.y) - mouse;
    
    for(int i = 0; i < 8; ++i) {
        p.xy = abs(p) / dot(p, p) - float2(0.9 + cos(time * 0.2) * 0.4);
    }
    
    return float4(p.x, p.x, p.y, 1.0);
}

kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    // mainImage expects a backbuffer; pass iChannel0 so the legacy code
    // compiles even though this shader doesn't sample it. The channel
    // arg buffer is sized to at least 1 slot whenever we have any input.
    // For shaders with no inputs, we still synthesize a fallback texture
    // (see PhosphorRuntime), so this call is always valid.
    texture2d<float, access::read> backbuffer = channels.iChannel0;
    float4 color = mainImage(float2(gid), uniforms->resolution, uniforms->mouse,
                             uniforms->time, uniforms->frame, backbuffer);
    color.a = 1.0;
    outTexture.write(color, gid);
}
