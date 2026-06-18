/* prompt: make this shader sexier */

/* phosphor:environment
output = 'image'
uniforms = []

[[passes]]
enabled = true
id = 'image'
inputs = []
output = 'image'

[[resources]]
id = 'image'
kind = 'texture2D'

[resources.spec]
flipTiming = 'endOfFrame'
format = 'rgba32Float'
initial = 'zero'
pingPong = false
size = 'drawable'*/

/// Draws a sensual, pulsing glow that follows the mouse with rainbow trails,
/// particle sparkles, and smooth color transitions. Background pulses with
/// warm colors when mouse button is held. A vibrant starburst marks the
/// click origin while held.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 p = float2(gid);
    float2 uv = p / uniforms.resolution;
    float t = uniforms.time;
    
    // Animated gradient background with subtle movement
    float bgWave = 0.5 + 0.5 * sin(uv.x * 3.0 + t * 0.5) * sin(uv.y * 2.0 - t * 0.3);
    float3 bgColor1 = float3(0.02, 0.01, 0.05);
    float3 bgColor2 = float3(0.08, 0.02, 0.12);
    float3 bg = mix(bgColor1, bgColor2, bgWave);
    
    // Warm pulse when button is held
    if (uniforms.mouseButtons != 0u) {
        float pulse = 0.5 + 0.5 * sin(t * 4.0);
        bg = mix(bg, float3(0.15, 0.02, 0.08), 0.5 + 0.3 * pulse);
    }
    
    // Rainbow hue based on time and position
    float hue = fract(t * 0.1 + length(p - uniforms.mouse) * 0.001);
    float3 rainbow;
    rainbow.r = abs(hue * 6.0 - 3.0) - 1.0;
    rainbow.g = 2.0 - abs(hue * 6.0 - 2.0);
    rainbow.b = 2.0 - abs(hue * 6.0 - 4.0);
    rainbow = clamp(rainbow, 0.0, 1.0);
    
    // Main glow at mouse position - softer, larger, pulsing
    float distMouse = length(p - uniforms.mouse);
    float pulse = 1.0 + 0.3 * sin(t * 3.0);
    float glowMouse = exp(-distMouse * 0.015 * pulse);
    float innerGlow = exp(-distMouse * 0.05);
    
    // Sparkle effect using pseudo-random noise
    float2 sparklePos = floor(p / 8.0);
    float sparkle = fract(sin(dot(sparklePos, float2(12.9898, 78.233)) + t) * 43758.5453);
    sparkle = pow(sparkle, 20.0) * exp(-distMouse * 0.01);
    
    // Combine mouse glow with rainbow tint
    float3 color = bg;
    color += rainbow * glowMouse * 0.8;
    color += float3(1.0, 0.95, 0.9) * innerGlow * 0.6;
    color += float3(1.0) * sparkle * 0.5;
    
    // Starburst at click origin while button is held
    if (uniforms.mouseButtons != 0u) {
        float2 toClick = p - uniforms.mouseClickOrigin;
        float distClick = length(toClick);
        float angle = atan2(toClick.y, toClick.x);
        
        // Rotating starburst rays
        float rays = pow(abs(sin(angle * 6.0 + t * 2.0)), 8.0);
        float starGlow = exp(-distClick * 0.02) * (0.5 + 0.5 * rays);
        float coreGlow = exp(-distClick * 0.08);
        
        // Gradient from pink to cyan
        float3 starColor = mix(float3(1.0, 0.2, 0.6), float3(0.2, 0.8, 1.0), 
                               0.5 + 0.5 * sin(t * 2.0));
        color += starColor * starGlow;
        color += float3(1.0, 0.9, 1.0) * coreGlow;
    }
    
    // Vignette for extra moodiness
    float vignette = 1.0 - 0.4 * length(uv - 0.5);
    color *= vignette;
    
    // Slight bloom/saturation boost
    color = pow(color, float3(0.95));
    
    outTexture.write(float4(clamp(color, 0.0, 1.0), 1.0), gid);
}
