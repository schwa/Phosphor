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
// Pulsing heart muscle shader
// This shader creates an organic, pulsing heart effect using mathematical patterns

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer) {
    float2 r = resolution;
    float2 p = (position.xy * 2.0 - r) / r.y;
    float2 n = float2(0), N = float2(0), q;
    float4 o = float4(0);
    float S = 5.0, a = 0.0, j = 0.0;
    float t = time;
    
    float2x2 m = rotate2D(5.0);
    
    for(; j < 30.0; j++) {
        p = p * m;
        n = n * m;
        q = p * S + j + n + t * 4.0 + sin(t * 4.0) * 0.8;
        a += dot(cos(q) / S, r / r);
        q = sin(q);
        n += q;
        N += q / (S + 20.0);
        S *= 1.2;
    }
    
    o += 0.1 - a * 0.1;
    o.r *= 5.0;
    o += min(0.7, 0.001 / length(N));
    o -= o * dot(p, p) * 0.7;

    return o;
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
