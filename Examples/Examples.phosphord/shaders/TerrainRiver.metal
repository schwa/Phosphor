/* phosphor:environment
flipY = true
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" } ]

[[textures]]
format = "rgba32Float"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "none"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];


// Ported from Phosphor 1's example library. mainImage is the legacy entry
// point; the kernel below wraps it with Phosphor 2's canonical signature.
// Terrain river shader
// Creates a landscape with a flowing river using raymarching and noise

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float2 r = resolution;
    float2 FC = position;
    float4 o = float4(0);
    float t = time;
    
    float i = 0.0, e = 0.0, g = 0.0, s = 0.0;
    
    for(; i < 100.0; i++) {
        float3 p = float3((FC.xy - 0.5 * r) / r.y * g, g - 5.0);
        p.y -= p.z * 0.6;
        p.z += t;
        
        e = p.y - tanh(abs(p.x + sin(p.z) * 0.5));
        
        for(s = 2.0; s < 1000.0; s += s) {
            float2 xz = p.xz * rotate2D(s);
            p.x = xz.x;
            p.z = xz.y;
            e += abs(dot(sin(p.xz * s), r / r / s / 4.0));
        }
        
        e = min(e, p.y) - 1.3;
        
        // FC.zzwz in twigl with 2D coords becomes (0,0,1,0)
        float4 zzwz = float4(0, 0, 1, 0);
        o += 0.01 - 0.01 / exp(e * 1e3 - sign(p.y - 1.31) * zzwz * 0.1);
        
        g += e * 0.4;
    }
    
    return o;
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
