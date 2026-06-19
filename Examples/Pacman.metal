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
name = "speed"
ui = { slider = { min = 0.1, max = 4.0 } }

[[uniforms]]
default = [ 1.0, 0.9, 0.0, 1.0 ]
kind = "color"
name = "pacmanColor"
ui = "color"

[[uniforms]]
default = [ 0.0, 0.0, 0.2, 1.0 ]
kind = "color"
name = "bgColor"
ui = "color"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];


// Signed distance function for a circle
float sdCircle(float2 p, float r) {
    return length(p) - r;
}

// Pac-Man shape with animated mouth
float sdPacman(float2 p, float mouthAngle) {
    // Mirror y to make mouth symmetric
    float2 mp = float2(p.x, abs(p.y));
    
    // Pac-Man body (circle)
    float body = sdCircle(mp, 0.35);
    
    // Mouth wedge - defined by angle from center
    float angle = atan2(mp.y, mp.x);
    float mouth = (angle < mouthAngle) ? -1.0 : 1.0;
    
    // Combine: inside circle AND outside mouth wedge
    return max(body, -mouth);
}

// Dot/pellet
float sdDot(float2 p, float r) {
    return sdCircle(p, r);
}

kernel void image(
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    float aspect = uniforms.resolution.x / uniforms.resolution.y;
    
    // Center and correct aspect ratio - flip Y to fix upside down issue
    float2 p = (uv - 0.5) * float2(aspect, -1.0);
    
    float speed = userUniforms.speed;
    float3 pacmanCol = userUniforms.pacmanColor.rgb;
    float3 bgCol = userUniforms.bgColor.rgb;
    
    // Animated mouth opening (chomping)
    float mouthAngle = 0.1 + 0.35 * (0.5 + 0.5 * sin(uniforms.time * 12.0 * speed));
    
    // Pac-Man position moving across screen
    float pacX = fmod(uniforms.time * 0.4 * speed, 2.0) - 1.0;
    float2 pacPos = p - float2(pacX, 0.0);
    
    // Draw Pac-Man
    float pacDist = sdPacman(pacPos, mouthAngle);
    
    // Eye position (now above the mouth since we flipped Y)
    float2 eyePos = pacPos - float2(0.05, 0.15);
    float eyeDist = sdCircle(eyePos, 0.04);
    
    // Create dots/pellets in a row
    float dotsDist = 1000.0;
    for (int i = -4; i < 6; i++) {
        float dotX = float(i) * 0.25;
        // Only show dots that Pac-Man hasn't eaten yet
        if (dotX > pacX + 0.2) {
            float2 dotPos = p - float2(dotX, 0.0);
            float d = sdDot(dotPos, 0.03);
            dotsDist = min(dotsDist, d);
        }
    }
    
    // Power pellet (larger, pulsing)
    float2 powerPos = p - float2(0.8, 0.0);
    float powerPulse = 0.05 + 0.02 * sin(uniforms.time * 5.0);
    float powerDist = (0.8 > pacX + 0.2) ? sdCircle(powerPos, powerPulse) : 1000.0;
    
    // Compose final color
    float3 col = bgCol;
    
    // Maze walls (simple horizontal lines)
    float wallY = abs(p.y) - 0.5;
    if (wallY > -0.03 && wallY < 0.0) {
        col = float3(0.0, 0.0, 0.8);
    }
    
    // Draw dots (white/cream colored)
    float dotSmooth = smoothstep(0.01, -0.01, dotsDist);
    col = mix(col, float3(1.0, 0.9, 0.7), dotSmooth);
    
    // Draw power pellet (slightly pink)
    float powerSmooth = smoothstep(0.01, -0.01, powerDist);
    col = mix(col, float3(1.0, 0.7, 0.7), powerSmooth);
    
    // Draw Pac-Man body
    float pacSmooth = smoothstep(0.01, -0.01, pacDist);
    col = mix(col, pacmanCol, pacSmooth);
    
    // Draw eye (black)
    float eyeSmooth = smoothstep(0.01, -0.01, eyeDist);
    col = mix(col, float3(0.0), eyeSmooth * pacSmooth);
    
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
