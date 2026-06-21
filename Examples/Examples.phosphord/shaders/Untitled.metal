/* prompt: Make a demo with rainbows */
/* prompt: add some user configurable sliders for whatever you feel like */

/* phosphor:environment
output = "image"

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" } ]

[[textures]]
format = "rgba16Float"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "none"

[[uniforms]]
default = 1.0
kind = "float"
name = "speed"
ui = { slider = { max = 3.0, min = 0.0 } }

[[uniforms]]
default = 1.0
kind = "float"
name = "waveIntensity"
ui = { slider = { max = 3.0, min = 0.0 } }

[[uniforms]]
default = 0.85
kind = "float"
name = "saturation"
ui = { slider = { max = 1.0, min = 0.0 } }

[[uniforms]]
default = 0.3
kind = "float"
name = "sparkleAmount"
ui = { slider = { max = 1.0, min = 0.0 } }

[[uniforms]]
default = 1.0
kind = "float"
name = "zoom"
ui = { slider = { max = 5.0, min = 0.2 } }
*/

uint2 gid [[thread_position_in_grid]];

/// Converts HSV color to RGB color space.
/// h, s, v should be in [0, 1] range.
float3 hsv2rgb(float h, float s, float v) {
    float3 c = float3(h, s, v);
    float3 rgb = clamp(abs(fmod(c.x * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return c.z * mix(float3(1.0), rgb, c.y);
}

/// Main image pass: renders animated rainbow waves that flow across the screen.
/// Creates multiple layered sine waves with shifting hues based on position and time.
/// User can control wave speed, intensity, saturation, sparkle amount, and zoom.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    if (gid.x >= uint(uniforms.resolution.x) || gid.y >= uint(uniforms.resolution.y)) return;
    
    float2 uv = float2(gid) / uniforms.resolution;
    float t = uniforms.time;
    
    // User-controlled parameters
    float speed = userUniforms.speed;
    float waveIntensity = userUniforms.waveIntensity;
    float saturation = userUniforms.saturation;
    float sparkleAmount = userUniforms.sparkleAmount;
    float zoom = userUniforms.zoom;
    
    // Apply zoom to UV coordinates (centered)
    float2 zoomedUV = (uv - 0.5) * zoom + 0.5;
    
    // Create flowing rainbow effect with multiple wave layers
    float wave1 = sin(zoomedUV.x * 10.0 + t * 2.0 * speed) * 0.1;
    float wave2 = sin(zoomedUV.x * 5.0 - t * 1.5 * speed + zoomedUV.y * 3.0) * 0.15;
    float wave3 = sin(zoomedUV.y * 8.0 + t * 1.2 * speed) * 0.08;
    
    // Combine waves to create dynamic distortion (scaled by intensity)
    float distortion = (wave1 + wave2 + wave3) * waveIntensity;
    
    // Create rainbow hue based on position and distortion
    float hue = fract(zoomedUV.x * 0.5 + zoomedUV.y * 0.3 + distortion + t * 0.1 * speed);
    
    // Add some brightness variation for depth
    float brightness = 0.8 + 0.2 * sin(zoomedUV.x * 15.0 + zoomedUV.y * 10.0 + t * 3.0 * speed);
    
    // Add radial glow from center
    float2 center = uv - 0.5;
    float radial = 1.0 - length(center) * 0.5;
    
    // Create the rainbow color with user-controlled saturation
    float3 rainbow = hsv2rgb(hue, saturation, brightness * radial);
    
    // Add some sparkle effect with user-controlled amount
    float sparkle = pow(sin(zoomedUV.x * 50.0 + t * 5.0 * speed) * sin(zoomedUV.y * 50.0 - t * 4.0 * speed), 8.0);
    rainbow += sparkle * sparkleAmount;
    
    // Clamp to valid range
    rainbow = clamp(rainbow, 0.0, 1.0);
    
    uniforms.textures.image.write(float4(rainbow, 1.0), gid);
}
