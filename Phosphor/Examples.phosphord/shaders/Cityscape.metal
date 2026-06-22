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
// Cityscape shader - SEMI-BROKEN: renders but with artifacts
// Creates a procedural cityscape using noise and fractal iterations

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float2 r = resolution;
    float2 FC = position;
    float4 o = float4(0);
    float t = time;
    
    float i = 0.0, s = 0.0, e = 0.0, m = 0.0;
    float3 d, w = float3(0), q, p;
    
    // FC.rgb with 2D coords becomes (x, y, 0)
    d = float3(FC.x, FC.y, 0) / r.y - 1.0;
    w += 4.0;
    
    for(; i < 200.0; i++) {
        s = 2.0;
        p = w + d * e;
        p.xz = p.xz * rotate2D(t * 0.2);
        
        q = round(p);
        p -= q;
        m = fsnoise(q.zx) * 4.0;
        p.y = w.y - m;
        
        for(int j = 0; j < 9; j++) {
            e = min(dot(p, p), 0.4) + 0.1;
            s /= e;
            p = abs(p) / e - 0.2;
            p.y -= m;
        }
        
        e = clamp(length(p) / s - m / s, w.y - m, 0.2) + i / 1e6;
        
        if(i > 100.0) {
            d /= d;  // This creates NaN/inf intentionally
            o = o;
        } else {
            o += exp(-e * 5e3);
        }
        
        w += d * e;
    }
    
    o *= e / 20.0;
    
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
