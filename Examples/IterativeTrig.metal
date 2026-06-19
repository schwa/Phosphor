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
// Iterative trigonometric pattern
// Creates complex patterns through iterative trigonometric transformations

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer) {
    float4 p = float4(position.xy / 4e2, 0, -4);

    for(int i = 0; i < 9; ++i) {
        p += float4(
            sin(-(p.x + time * 0.2)) + atan(p.y * p.w),
            cos(-p.x) + atan(p.z * p.w),
            cos(-(p.x + sin(time * 0.8))) + atan(p.z * p.w),
            0
        );
    }
    
    return p;
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
