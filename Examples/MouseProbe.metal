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

/// HAL 9000 eye that tracks the mouse position, with animated closing pod-bay
/// doors. Uses uniforms.mouse + uniforms.time. Pure procedural.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 p = float2(gid);
    float2 uv = p / uniforms.resolution;
    float2 center = uniforms.resolution * 0.5;
    float t = uniforms.time;

    float3 bg = float3(0.02, 0.02, 0.03);
    float noise = fract(sin(dot(floor(p / 4.0), float2(12.9898, 78.233))) * 43758.5453);
    bg += float3(0.01) * noise;

    float2 eyeCenter = center;
    float2 toMouse = uniforms.mouse - center;
    eyeCenter += toMouse * 0.05;

    float distEye = length(p - eyeCenter);
    float eyeRadius = min(uniforms.resolution.x, uniforms.resolution.y) * 0.15;

    float ring = smoothstep(eyeRadius * 1.1, eyeRadius * 1.05, distEye) *
                 smoothstep(eyeRadius * 0.95, eyeRadius, distEye);
    float3 ringColor = float3(0.3, 0.32, 0.35);
    float innerDark = smoothstep(eyeRadius, eyeRadius * 0.9, distEye);
    float redGlow = exp(-distEye * 0.025);
    float coreGlow = exp(-distEye * 0.06);
    float pulse = 0.7 + 0.3 * sin(t * 1.5);

    float3 halRed = float3(1.0, 0.1, 0.05) * pulse;
    float3 halCore = float3(1.0, 0.4, 0.3);

    float doorProgress = clamp(t * 0.1, 0.0, 0.45);
    float doorTop = uniforms.resolution.y * doorProgress;
    float doorBottom = uniforms.resolution.y * (1.0 - doorProgress);

    float3 doorColor = float3(0.15, 0.16, 0.18);
    float doorLines = abs(sin(p.x * 0.02)) * 0.3;
    doorColor += doorLines * float3(0.05);

    float topEdge = smoothstep(doorTop - 5.0, doorTop, p.y) * smoothstep(doorTop + 5.0, doorTop, p.y);
    float bottomEdge = smoothstep(doorBottom + 5.0, doorBottom, p.y) * smoothstep(doorBottom - 5.0, doorBottom, p.y);

    float3 color = bg;
    color += halRed * redGlow * 0.3;
    color = mix(color, float3(0.01), innerDark * 0.9);
    color += halRed * coreGlow * innerDark;
    color += halCore * exp(-distEye * 0.15) * innerDark;
    color = mix(color, ringColor, ring);

    float2 reflectPos = eyeCenter + float2(-eyeRadius * 0.3, -eyeRadius * 0.3);
    float reflection = exp(-length(p - reflectPos) * 0.08);
    color += float3(0.3) * reflection * innerDark;

    if (p.y < doorTop) {
        color = doorColor;
        color += float3(0.1) * topEdge;
        color += halRed * 0.1 * (1.0 - p.y / doorTop);
    }
    if (p.y > doorBottom) {
        color = doorColor;
        color += float3(0.1) * bottomEdge;
        color += halRed * 0.1 * ((p.y - doorBottom) / (uniforms.resolution.y - doorBottom));
    }

    float seamX = abs(p.x - center.x);
    if (seamX < 2.0 && (p.y < doorTop || p.y > doorBottom)) {
        color = float3(0.05);
    }

    float vignette = 1.0 - 0.5 * length(uv - 0.5);
    color *= vignette;
    float flicker = 1.0 - 0.05 * step(0.98, fract(t * 7.0));
    color *= flicker;

    uniforms.textures.image.write(float4(clamp(color, 0.0, 1.0), 1.0), gid);
}
