/* prompt: Make me a shader with rainbows! Make some parameters user configurable */

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
ui = { slider = { max = 5.0, min = 0.0 } }

[[uniforms]]
default = 3.0
kind = "float"
name = "scale"
ui = { slider = { max = 10.0, min = 0.5 } }

[[uniforms]]
default = 1.0
kind = "float"
name = "saturation"
ui = { slider = { max = 1.0, min = 0.0 } }

[[uniforms]]
default = 1.0
kind = "float"
name = "brightness"
ui = { slider = { max = 1.0, min = 0.0 } }
*/

uint2 gid [[thread_position_in_grid]];

/// Converts HSV color to RGB color.
/// h, s, v are expected in [0, 1] range.
float3 hsv2rgb(float h, float s, float v) {
    float3 c = float3(h, s, v);
    float3 rgb = clamp(abs(fmod(c.x * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return c.z * mix(float3(1.0), rgb, c.y);
}

/// Main image pass: renders animated rainbow waves across the screen.
/// Reads no inputs, writes to the 'image' output texture.
/// User can control wave speed, scale, saturation, and brightness.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    // Bounds check
    if (gid.x >= uint(uniforms.resolution.x) || gid.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    // Normalized UV coordinates
    float2 uv = float2(gid) / uniforms.resolution;
    
    // Center the coordinates for radial effects
    float2 centered = uv - 0.5;
    centered.x *= uniforms.resolution.x / uniforms.resolution.y; // Aspect ratio correction
    
    // Create multiple rainbow patterns
    float time = uniforms.time * userUniforms.speed;
    
    // Diagonal wave pattern
    float diagonal = (uv.x + uv.y) * userUniforms.scale;
    
    // Radial wave pattern
    float radial = length(centered) * userUniforms.scale * 2.0;
    
    // Combine patterns with time animation
    float hue = fract(diagonal * 0.5 + radial * 0.3 + time * 0.2);
    
    // Add some wave distortion
    hue += sin(uv.x * 10.0 * userUniforms.scale + time) * 0.05;
    hue += cos(uv.y * 8.0 * userUniforms.scale + time * 1.3) * 0.05;
    hue = fract(hue);
    
    // Convert HSV to RGB with user-controlled saturation and brightness
    float3 color = hsv2rgb(hue, userUniforms.saturation, userUniforms.brightness);
    
    // Add subtle sparkle effect
    float sparkle = fract(sin(dot(float2(gid), float2(12.9898, 78.233)) + time) * 43758.5453);
    sparkle = pow(sparkle, 20.0) * 0.3;
    color += sparkle;
    
    // Clamp to valid range
    color = clamp(color, 0.0, 1.0);
    
    uniforms.textures.image.write(float4(color, 1.0), gid);
}

