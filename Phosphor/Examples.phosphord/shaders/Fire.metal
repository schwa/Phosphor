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

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame) {
    float2 uv = position / resolution.xy;
    float2 firePos = uv;
    firePos.x = (firePos.x - 0.5) * (1.0 + uv.y * 2.0) + 0.5;

    float2 noiseCoord = firePos * float2(10.0, 6.0);
    noiseCoord.y -= time * 3.0;

    float noise = 0.0;
    noise += sin(noiseCoord.x * 1.5 + sin(noiseCoord.y * 1.2)) * 0.5;
    noise += sin(noiseCoord.y * 2.0 + cos(noiseCoord.x * 0.8) + time * 3.0) * 0.3;
    noise += cos(noiseCoord.x * 3.0 + sin(noiseCoord.y * 2.5 + time * 2.0)) * 0.2;
    noise += sin(noiseCoord.x * 5.0 - noiseCoord.y * 3.0 + time * 4.0) * 0.15;

    float horizontalWave = sin(firePos.x * 15.0 + time * 2.0) * 0.1;
    noise += horizontalWave;

    float2 swirlCoord = noiseCoord;
    swirlCoord.x += sin(swirlCoord.y * 0.5 + time) * 0.3;
    noise += sin(swirlCoord.x * 4.0) * 0.1;

    float flames = noise * 0.5 + 0.5;
    float verticalVar = sin(firePos.x * 8.0 + sin(time * 2.0) * 2.0) * 0.2;
    flames += verticalVar * (1.0 - uv.y);

    float fireNoise = flames;
    float fireShape = fireNoise - uv.y * 1.5;
    fireShape = smoothstep(0.0, 0.4, fireShape);

    float core = 1.0 - length((uv - float2(0.5, 0.0)) * float2(3.0, 1.5));
    core = smoothstep(0.0, 0.7, core);
    fireShape = max(fireShape, core);

    float3 color = float3(0.0);
    if(fireShape > 0.8) {
        color = float3(1.0, 0.95, 0.8);
    } else if(fireShape > 0.6) {
        float t = (fireShape - 0.6) / 0.2;
        color = mix(float3(1.0, 0.6, 0.0), float3(1.0, 0.95, 0.8), t);
    } else if(fireShape > 0.3) {
        float t = (fireShape - 0.3) / 0.3;
        color = mix(float3(0.8, 0.2, 0.0), float3(1.0, 0.6, 0.0), t);
    } else if(fireShape > 0.0) {
        float t = fireShape / 0.3;
        color = float3(0.8 * t, 0.2 * t, 0.0);
    }

    float flicker = 0.9 + 0.1 * sin(time * 20.0 + fsnoise(uv * 10.0) * 5.0);
    color *= flicker;
    float glow = smoothstep(0.0, 1.0, fireShape);
    color += float3(1.0, 0.4, 0.1) * glow * 0.3;

    float sparkNoise = fsnoise(uv * 50.0 + float2(0, time * 100.0));
    if(sparkNoise > 0.98 && fireShape > 0.3) {
        color += float3(1.0, 0.8, 0.4) * 0.5;
    }

    float3 background = float3(0.1, 0.02, 0.01) * (1.0 + fireShape * 0.5);
    color = mix(background, color, fireShape);
    return float4(color, 1.0);
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
