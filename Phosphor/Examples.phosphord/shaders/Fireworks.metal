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



/// Helper: pseudo-random hash function
float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

/// Helper: creates a single firework explosion
float3 firework(float2 uv, float2 center, float t, float seed) {
    float3 color = float3(
        0.5 + 0.5 * sin(seed * 6.28),
        0.5 + 0.5 * sin(seed * 6.28 + 2.094),
        0.5 + 0.5 * sin(seed * 6.28 + 4.188)
    );
    
    float brightness = 0.0;
    
    // Create particles radiating outward
    for (int i = 0; i < 32; i++) {
        float angle = float(i) * 6.28318 / 32.0 + seed * 10.0;
        float speed = 0.3 + 0.2 * hash(float2(seed, float(i)));
        
        // Particle position with gravity
        float2 particlePos = center + float2(cos(angle), sin(angle)) * speed * t;
        particlePos.y -= 0.5 * t * t; // gravity
        
        float dist = length(uv - particlePos);
        float fade = max(0.0, 1.0 - t * 0.8);
        float sparkle = 1.0 + 0.5 * sin(t * 20.0 + float(i));
        brightness += (0.003 / (dist + 0.001)) * fade * sparkle;
    }
    
    return color * brightness;
}

/// Main fireworks kernel: renders multiple animated firework bursts
/// across the screen with colorful particle trails and gravity.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) - 0.5 * res) / res.y;
    
    float time = uniforms.time;
    float3 col = float3(0.0);
    
    // Dark blue night sky gradient
    float3 sky = mix(float3(0.0, 0.0, 0.05), float3(0.02, 0.02, 0.1), 1.0 - float(gid.y) / res.y);
    col = sky;
    
    // Multiple fireworks with different timings
    for (int i = 0; i < 6; i++) {
        float seed = float(i) * 0.17 + 0.5;
        float period = 2.5 + hash(float2(seed, 0.0)) * 1.5;
        float offset = hash(float2(seed, 1.0)) * period;
        
        float localTime = fmod(time + offset, period);
        
        // Launch phase (rocket going up)
        float launchDuration = 0.6;
        float explosionStart = launchDuration;
        
        // Firework center position
        float2 center;
        center.x = -0.6 + hash(float2(seed, 2.0)) * 1.2;
        center.y = -0.5 + hash(float2(seed, 3.0)) * 0.3 + 0.4;
        
        if (localTime < launchDuration) {
            // Draw rising rocket trail
            float launchProgress = localTime / launchDuration;
            float2 rocketPos = float2(center.x, -0.6 + launchProgress * (center.y + 0.6));
            float dist = length(uv - rocketPos);
            float3 trailColor = float3(1.0, 0.8, 0.3);
            col += trailColor * (0.002 / (dist + 0.001)) * (1.0 - launchProgress);
        } else {
            // Explosion
            float explosionTime = localTime - explosionStart;
            if (explosionTime < 2.0) {
                col += firework(uv, center, explosionTime, seed);
            }
        }
    }
    
    // Add some twinkling stars
    float2 starUV = float2(gid) * 0.1;
    float star = hash(floor(starUV));
    if (star > 0.995) {
        float twinkle = 0.5 + 0.5 * sin(time * 3.0 + star * 100.0);
        col += float3(0.3) * twinkle;
    }
    
    // Tone mapping and output
    col = clamp(col, 0.0, 1.0);
    uniforms.textures.image.write(float4(col, 1.0), gid);
}


