/* phosphor:environment
flipY = true
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" } ]

[[textures]]
format = "rgba8Unorm"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "none"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];

/// Animated falling confetti particles in various colors / sizes / rotations.
/// Procedural, no inputs.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = float2(gid) / res;
    float t = uniforms.time;

    float3 bg = mix(float3(0.1, 0.1, 0.15), float3(0.2, 0.15, 0.25), uv.y);
    float3 col = bg;

    int numParticles = 80;
    for (int i = 0; i < numParticles; i++) {
        float fi = float(i);
        float r1 = fract(sin(fi * 12.9898) * 43758.5453);
        float r2 = fract(sin(fi * 78.233) * 43758.5453);
        float r3 = fract(sin(fi * 45.164) * 43758.5453);
        float r4 = fract(sin(fi * 94.673) * 43758.5453);
        float r5 = fract(sin(fi * 23.421) * 43758.5453);

        float size = 0.015 + r1 * 0.02;
        float speed = 0.15 + r2 * 0.25;
        float xPos = r3;
        float wobble = sin(t * (2.0 + r4 * 3.0) + fi) * 0.05;

        float yPos = fract(-t * speed + r4);
        float2 pos = float2(xPos + wobble, yPos);

        float2 aspect = float2(res.x / res.y, 1.0);
        float2 diff = (uv - pos) * aspect;

        float angle = t * (1.0 + r5 * 2.0) + fi;
        float ca = cos(angle);
        float sa = sin(angle);
        diff = float2(diff.x * ca - diff.y * sa, diff.x * sa + diff.y * ca);

        float2 rectSize = float2(size, size * (0.4 + r5 * 0.4));
        float2 d = abs(diff) - rectSize;
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);

        float3 confettiCol;
        int colorIdx = i % 6;
        if (colorIdx == 0) confettiCol = float3(1.0, 0.2, 0.3);
        else if (colorIdx == 1) confettiCol = float3(0.2, 0.8, 0.4);
        else if (colorIdx == 2) confettiCol = float3(0.2, 0.5, 1.0);
        else if (colorIdx == 3) confettiCol = float3(1.0, 0.9, 0.2);
        else if (colorIdx == 4) confettiCol = float3(1.0, 0.5, 0.1);
        else confettiCol = float3(0.9, 0.3, 0.9);

        float shade = 0.7 + 0.3 * abs(sin(angle * 2.0));
        confettiCol *= shade;
        float alpha = 1.0 - smoothstep(0.0, 0.003, dist);
        col = mix(col, confettiCol, alpha);
    }

    uniforms.textures.image.write(float4(col, 1.0), gid);
}
