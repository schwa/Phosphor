/* phosphor:environment
output = "image"

[[textures]]
id = "image"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]

[[uniforms]]
default = 1.0
kind = "float"
name = "scrollSpeed"
ui = { slider = { min = 0.0, max = 4.0 } }

[[uniforms]]
default = [ 0.4, 0.7, 1.0, 1.0 ]
kind = "color"
name = "skyColor"
ui = "color"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];




// Super Mario inspired pixel art shader

float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Draw a pixel-art block pattern
float blockPattern(float2 uv, float size) {
    float2 grid = floor(uv / size);
    float2 local = fract(uv / size);
    // Add brick mortar lines
    float mortarX = step(0.95, local.x);
    float mortarY = step(0.95, local.y);
    return 1.0 - max(mortarX, mortarY);
}

// Question block with ? mark
float3 questionBlock(float2 uv, float time) {
    float3 yellow = float3(1.0, 0.8, 0.2);
    float3 darkYellow = float3(0.8, 0.5, 0.1);
    
    // Bouncing animation
    float bounce = abs(sin(time * 3.0)) * 0.02;
    uv.y -= bounce;
    
    // Block base
    float block = blockPattern(uv, 1.0);
    
    // Question mark (simplified)
    float2 center = uv - 0.5;
    float qMark = smoothstep(0.15, 0.1, length(center - float2(0.0, 0.1)));
    qMark += smoothstep(0.06, 0.03, length(center - float2(0.0, -0.25)));
    
    return mix(yellow, darkYellow, 1.0 - block) * (1.0 - qMark * 0.3);
}

// Simple cloud shape
float cloud(float2 uv, float2 pos, float size) {
    float2 p = (uv - pos) / size;
    float d = length(p);
    d = min(d, length(p - float2(-0.3, 0.0)));
    d = min(d, length(p - float2(0.3, 0.0)));
    d = min(d, length(p - float2(0.15, 0.2)));
    d = min(d, length(p - float2(-0.15, 0.2)));
    return smoothstep(0.35, 0.3, d);
}

// Pipe
float3 pipe(float2 uv, float2 pos, float width, float height) {
    float2 p = uv - pos;
    float3 green = float3(0.1, 0.7, 0.2);
    float3 darkGreen = float3(0.05, 0.4, 0.1);
    
    // Pipe body
    float body = step(abs(p.x), width * 0.4) * step(0.0, p.y) * step(p.y, height);
    // Pipe top (wider)
    float top = step(abs(p.x), width * 0.5) * step(height, p.y) * step(p.y, height + 0.05);
    
    float3 col = mix(green, darkGreen, smoothstep(-width * 0.2, width * 0.2, p.x));
    return col * (body + top);
}

// Ground blocks
float3 ground(float2 uv, float time) {
    float3 brown = float3(0.6, 0.3, 0.1);
    float3 darkBrown = float3(0.4, 0.2, 0.05);
    
    float pattern = blockPattern(uv * 8.0 + float2(time * 0.5, 0.0), 1.0);
    return mix(darkBrown, brown, pattern);
}

// Coin
float coin(float2 uv, float2 pos, float time) {
    float2 p = uv - pos;
    // Spinning effect
    float spin = abs(sin(time * 4.0));
    p.x /= max(0.2, spin);
    return smoothstep(0.04, 0.03, length(p));
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    // Flip the Y coordinate to fix upside-down rendering
    float2 uv = float2(gid) / uniforms.resolution;
    uv.y = 1.0 - uv.y;
    
    float time = uniforms.time * userUniforms.scrollSpeed;
    
    // Sky gradient
    float3 skyTop = float3(userUniforms.skyColor.rgb);
    float3 skyBottom = skyTop + float3(0.2, 0.1, 0.0);
    float3 col = mix(skyBottom, skyTop, uv.y);
    
    // Scrolling offset
    float scroll = time * 0.3;
    
    // Clouds (parallax layers)
    float c1 = cloud(uv, float2(fract(0.2 - scroll * 0.1), 0.8), 0.15);
    float c2 = cloud(uv, float2(fract(0.6 - scroll * 0.15), 0.75), 0.12);
    float c3 = cloud(uv, float2(fract(0.9 - scroll * 0.12), 0.85), 0.18);
    col = mix(col, float3(1.0), max(c1, max(c2, c3)));
    
    // Hills in background
    float hill1 = smoothstep(0.0, 0.15, 0.25 + 0.08 * sin((uv.x + scroll * 0.2) * 6.0) - uv.y);
    float hill2 = smoothstep(0.0, 0.1, 0.2 + 0.05 * sin((uv.x + scroll * 0.25) * 8.0 + 2.0) - uv.y);
    col = mix(col, float3(0.3, 0.7, 0.3), hill1 * 0.5);
    col = mix(col, float3(0.2, 0.6, 0.2), hill2 * 0.6);
    
    // Ground
    if (uv.y < 0.2) {
        col = ground(uv, scroll);
    }
    
    // Pipes at different positions
    float pipeX1 = fract(0.3 - scroll * 0.3);
    float pipeX2 = fract(0.7 - scroll * 0.3);
    float3 pipeCol = pipe(uv, float2(pipeX1, 0.2), 0.08, 0.15);
    pipeCol += pipe(uv, float2(pipeX2, 0.2), 0.08, 0.25);
    col = mix(col, pipeCol, step(0.01, length(pipeCol)));
    
    // Question blocks floating
    float blockX = fract(0.5 - scroll * 0.3);
    if (abs(uv.x - blockX) < 0.04 && abs(uv.y - 0.5) < 0.04) {
        float2 blockUV = (uv - float2(blockX - 0.04, 0.46)) * 12.5;
        col = questionBlock(blockUV, uniforms.time);
    }
    
    // Floating coins
    float coinGlow = coin(uv, float2(fract(0.35 - scroll * 0.3), 0.45), uniforms.time);
    coinGlow += coin(uv, float2(fract(0.55 - scroll * 0.3), 0.55), uniforms.time + 0.5);
    coinGlow += coin(uv, float2(fract(0.75 - scroll * 0.3), 0.45), uniforms.time + 1.0);
    col = mix(col, float3(1.0, 0.85, 0.2), coinGlow);
    
    // Add slight pixelation effect for retro feel
    float2 pixelUV = floor(uv * 180.0) / 180.0;
    float pixelNoise = hash(pixelUV + floor(uniforms.time * 10.0)) * 0.03;
    col += pixelNoise;
    
    uniforms.textures.image.write(float4(col, 1.0), gid);
}


