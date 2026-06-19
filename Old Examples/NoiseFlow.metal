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
// Noise flow shader
// Creates flowing landscapes using simplex noise and raymarching

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float2 r = resolution;
    float2 FC = position;
    float4 o = float4(0);
    float t = time;
    
    float3 d = float3(FC.xy * 2.0 - r, r.x) / r.x;
    float3 p = float3(0);
    
    for(float i = 0.0, s = 0.0; i < 200.0; i++) {
        s = exp(fmod(i, 5.0));
        p += d * (p.y + 0.2 - 0.2 * snoise2D((p.xz * 0.6 + t * 0.2) * s)) / s;
    }
    
    float3 temp = d + 0.03 * (d + 1.0) / length(d.xy - 1.3) - 0.7 / (p.z + 1.0) - min(0.2 + p + p, float3(0)).y;
    o.grb = 0.5 * temp;
    
    return o;
}

kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float4 color = mainImage(float2(gid), uniforms->resolution, uniforms->mouse,
                             uniforms->time, uniforms->frame);
    color.a = 1.0;
    outTexture.write(color, gid);
}
