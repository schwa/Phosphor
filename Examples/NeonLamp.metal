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
// Neon Lamp - Simulates glowing neon lights with realistic bloom and flicker
// Creates two animated neon shapes:
// 1. A circular ring in pink/purple that moves in a gentle pattern
// 2. A vertical bar in cyan that moves independently
//
// Implementation details:
// - Core geometry: Uses distance fields (ring: abs(dist - radius) - thickness, bar: abs(x - center) - width)
// - Multi-layer glow: 5 iterations with increasing radius, each contributing 0.005/(distance + glowRadius)
//   This creates a 1/r falloff that mimics real light diffusion through air
// - Animated glow intensity: Multiplies glow by sine wave (0.8 + 0.2 * sin(time + position))
//   Creates pulsing effect that travels along the neon tube
// - Flicker effect: finalColor *= (0.95 + 0.05 * sin(time * 30 + noise))
//   High frequency (30Hz) sine combined with noise creates realistic electrical fluctuation
//   95% base intensity ensures the light never goes completely dark
// - Additive blending: Both neon colors are added together, allowing overlapping glows to brighten
// - Ambient light: Adds float3(0.02, 0.01, 0.03) to prevent pure black background

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float2 uv = position / resolution.xy;
    float2 center = float2(0.5, 0.5);
    
    float3 finalColor = float3(0.0);
    
    float lampRadius = 0.15;
    float lampThickness = 0.02;
    float2 lampPos = center + float2(sin(time * 0.5) * 0.2, cos(time * 0.7) * 0.1);
    
    float dist = length(uv - lampPos);
    float ring = abs(dist - lampRadius) - lampThickness;
    
    float3 neonColor = float3(1.0, 0.1, 0.8);
    
    float intensity = 0.0;
    if (ring < 0.0) {
        intensity = 1.0;
    }
    
    float glow = 0.0;
    for (float i = 0.0; i < 5.0; i++) {
        float glowRadius = 0.02 + i * 0.015;
        glow += 0.005 / (abs(dist - lampRadius) + glowRadius);
    }
    
    glow *= 0.8 + 0.2 * sin(time * 3.0 + dist * 10.0);
    
    finalColor = neonColor * intensity + neonColor * glow;
    
    float2 lampPos2 = center + float2(cos(time * 0.6) * 0.25, sin(time * 0.4) * 0.15);
    dist = length(uv - lampPos2);
    float verticalBar = abs(uv.x - lampPos2.x) - 0.015;
    float barHeight = 0.2;
    float barMask = smoothstep(lampPos2.y - barHeight, lampPos2.y - barHeight + 0.01, uv.y) * 
                    smoothstep(lampPos2.y + barHeight, lampPos2.y + barHeight - 0.01, uv.y);
    
    float3 neonColor2 = float3(0.1, 0.8, 1.0);
    
    float intensity2 = 0.0;
    if (verticalBar < 0.0 && barMask > 0.0) {
        intensity2 = 1.0 * barMask;
    }
    
    float glow2 = 0.0;
    for (float i = 0.0; i < 5.0; i++) {
        float glowRadius = 0.02 + i * 0.015;
        glow2 += 0.005 / (abs(uv.x - lampPos2.x) + glowRadius);
    }
    glow2 *= barMask;
    glow2 *= 0.8 + 0.2 * sin(time * 4.0 - uv.y * 20.0);
    
    finalColor += neonColor2 * intensity2 + neonColor2 * glow2;
    
    float flicker = 0.95 + 0.05 * sin(time * 30.0 + fsnoise(float2(time * 10.0, 0.0)));
    finalColor *= flicker;
    
    finalColor += float3(0.02, 0.01, 0.03);
    
    finalColor = clamp(finalColor, 0.0, 1.0);
    
    return float4(finalColor, 1.0);
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
