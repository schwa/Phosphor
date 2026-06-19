/* prompt: confetti? */

/* phosphor:environment
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
inputs = []
output = "image"

[[resources]]
id = "image"
kind = "texture2D"

    [resources.spec]
    flipTiming = "endOfFrame"
    format = "rgba8Unorm"
    initial = "zero"
    pingPong = false
    size = "drawable"*/

/// Renders animated falling confetti particles with various colors,
/// sizes, and rotation. Each particle is procedurally generated using
/// pseudo-random functions based on particle ID.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 res = uniforms->resolution;
    float2 uv = float2(gid) / res;
    float t = uniforms->time;
    
    // Background gradient
    float3 bg = mix(float3(0.1, 0.1, 0.15), float3(0.2, 0.15, 0.25), uv.y);
    float3 col = bg;
    
    // Number of confetti particles
    int numParticles = 80;
    
    for (int i = 0; i < numParticles; i++) {
        // Pseudo-random values for this particle
        float fi = float(i);
        float r1 = fract(sin(fi * 12.9898) * 43758.5453);
        float r2 = fract(sin(fi * 78.233) * 43758.5453);
        float r3 = fract(sin(fi * 45.164) * 43758.5453);
        float r4 = fract(sin(fi * 94.673) * 43758.5453);
        float r5 = fract(sin(fi * 23.421) * 43758.5453);
        
        // Particle properties
        float size = 0.015 + r1 * 0.02;
        float speed = 0.15 + r2 * 0.25;
        float xPos = r3;
        float wobble = sin(t * (2.0 + r4 * 3.0) + fi) * 0.05;
        
        // Particle position (falling down, wrapping)
        float yPos = fract(-t * speed + r4);
        float2 pos = float2(xPos + wobble, yPos);
        
        // Aspect ratio correction
        float2 aspect = float2(res.x / res.y, 1.0);
        float2 diff = (uv - pos) * aspect;
        
        // Rotation
        float angle = t * (1.0 + r5 * 2.0) + fi;
        float ca = cos(angle);
        float sa = sin(angle);
        diff = float2(diff.x * ca - diff.y * sa, diff.x * sa + diff.y * ca);
        
        // Rectangle shape (confetti piece)
        float2 rectSize = float2(size, size * (0.4 + r5 * 0.4));
        float2 d = abs(diff) - rectSize;
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        
        // Confetti color (bright, saturated colors)
        float3 confettiCol;
        int colorIdx = i % 6;
        if (colorIdx == 0) confettiCol = float3(1.0, 0.2, 0.3);      // Red
        else if (colorIdx == 1) confettiCol = float3(0.2, 0.8, 0.4); // Green
        else if (colorIdx == 2) confettiCol = float3(0.2, 0.5, 1.0); // Blue
        else if (colorIdx == 3) confettiCol = float3(1.0, 0.9, 0.2); // Yellow
        else if (colorIdx == 4) confettiCol = float3(1.0, 0.5, 0.1); // Orange
        else confettiCol = float3(0.9, 0.3, 0.9);                     // Pink
        
        // Add some shading based on rotation
        float shade = 0.7 + 0.3 * abs(sin(angle * 2.0));
        confettiCol *= shade;
        
        // Draw particle with smooth edges
        float alpha = 1.0 - smoothstep(0.0, 0.003, dist);
        col = mix(col, confettiCol, alpha);
    }
    
    outTexture.write(float4(col, 1.0), gid);
}
