/* prompt: make this shader sexier */
/* prompt: close the pod bay doors  */

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

/// I'm sorry Dave, I'm afraid I can't do that. Draws a menacing red HAL 9000 eye
/// that watches the mouse position, with animated closing pod bay door panels
/// and ominous pulsing glow. The eye tracks movement and the doors slowly close.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 p = float2(gid);
    float2 uv = p / uniforms.resolution;
    float2 center = uniforms.resolution * 0.5;
    float t = uniforms.time;
    
    // Dark, cold spaceship interior background
    float3 bg = float3(0.02, 0.02, 0.03);
    float noise = fract(sin(dot(floor(p / 4.0), float2(12.9898, 78.233))) * 43758.5453);
    bg += float3(0.01) * noise; // subtle texture
    
    // HAL 9000 eye - tracks mouse slightly
    float2 eyeCenter = center;
    float2 toMouse = uniforms.mouse - center;
    eyeCenter += toMouse * 0.05; // subtle tracking
    
    float distEye = length(p - eyeCenter);
    float eyeRadius = min(uniforms.resolution.x, uniforms.resolution.y) * 0.15;
    
    // Outer ring (silver/grey)
    float ring = smoothstep(eyeRadius * 1.1, eyeRadius * 1.05, distEye) *
                 smoothstep(eyeRadius * 0.95, eyeRadius, distEye);
    float3 ringColor = float3(0.3, 0.32, 0.35);
    
    // Inner dark area
    float innerDark = smoothstep(eyeRadius, eyeRadius * 0.9, distEye);
    
    // Red glowing center - the menacing eye
    float redGlow = exp(-distEye * 0.025);
    float coreGlow = exp(-distEye * 0.06);
    float pulse = 0.7 + 0.3 * sin(t * 1.5); // slow, ominous pulse
    
    // Menacing red color
    float3 halRed = float3(1.0, 0.1, 0.05) * pulse;
    float3 halCore = float3(1.0, 0.4, 0.3);
    
    // Pod bay doors - closing from top and bottom
    float doorProgress = clamp(t * 0.1, 0.0, 0.45); // slowly closing
    float doorTop = uniforms.resolution.y * doorProgress;
    float doorBottom = uniforms.resolution.y * (1.0 - doorProgress);
    
    // Door panels with metallic look
    float3 doorColor = float3(0.15, 0.16, 0.18);
    float doorLines = abs(sin(p.x * 0.02)) * 0.3;
    doorColor += doorLines * float3(0.05);
    
    // Add door edge highlights
    float topEdge = smoothstep(doorTop - 5.0, doorTop, p.y) * smoothstep(doorTop + 5.0, doorTop, p.y);
    float bottomEdge = smoothstep(doorBottom + 5.0, doorBottom, p.y) * smoothstep(doorBottom - 5.0, doorBottom, p.y);
    
    // Compose the scene
    float3 color = bg;
    
    // Add HAL's glow to background
    color += halRed * redGlow * 0.3;
    
    // HAL eye components
    color = mix(color, float3(0.01), innerDark * 0.9);
    color += halRed * coreGlow * innerDark;
    color += halCore * exp(-distEye * 0.15) * innerDark;
    color = mix(color, ringColor, ring);
    
    // Reflection spot on the eye
    float2 reflectPos = eyeCenter + float2(-eyeRadius * 0.3, -eyeRadius * 0.3);
    float reflection = exp(-length(p - reflectPos) * 0.08);
    color += float3(0.3) * reflection * innerDark;
    
    // Draw the closing doors
    if (p.y < doorTop) {
        color = doorColor;
        color += float3(0.1) * topEdge; // highlight at edge
        // Red warning light reflection on door
        color += halRed * 0.1 * (1.0 - p.y / doorTop);
    }
    if (p.y > doorBottom) {
        color = doorColor;
        color += float3(0.1) * bottomEdge;
        color += halRed * 0.1 * ((p.y - doorBottom) / (uniforms.resolution.y - doorBottom));
    }
    
    // Door seam lines
    float seamX = abs(p.x - center.x);
    if (seamX < 2.0 && (p.y < doorTop || p.y > doorBottom)) {
        color = float3(0.05);
    }
    
    // Vignette
    float vignette = 1.0 - 0.5 * length(uv - 0.5);
    color *= vignette;
    
    // Occasional flicker for unease
    float flicker = 1.0 - 0.05 * step(0.98, fract(t * 7.0));
    color *= flicker;
    
    outTexture.write(float4(clamp(color, 0.0, 1.0), 1.0), gid);
}
