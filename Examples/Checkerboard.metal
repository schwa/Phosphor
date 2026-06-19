/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

[[passes]]
id = "image"
output = "image"
*/

#include "Phosphor.h"

// Ported from Phosphor 1's example library. mainImage is the legacy entry
// point; the kernel below wraps it with Phosphor 2's canonical signature.
// Simple checkerboard pattern
// Creates a black and white checkerboard grid

/// Main shader function that calculates the color for each pixel
/// @param position The pixel coordinate in screen space (0,0 is bottom-left, resolution.x,resolution.y is top-right)
/// @param resolution The viewport size in pixels (width, height)
/// @param mouse The normalized mouse position (0.0 to 1.0 in both x and y)
/// @param time The elapsed time in seconds since the shader started
/// @param frame The current frame number (increments by 1 each frame)
/// @param backbuffer The texture containing the previous frame's output (for feedback effects)
/// @return A float4 color value (red, green, blue, alpha) where each component is 0.0 to 1.0
float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer) {
    // Base size of each checker square in pixels
    float baseSize = 50.0;
    
    // Animate the checker size with a sine wave (pulsing effect)
    // Size oscillates between 30 and 70 pixels
    float checkerSize = baseSize + sin(time * 0.5) * 20.0;
    
    // Add scrolling motion - moves diagonally
    float2 scrollOffset = float2(time * 10.0, time * 7.0);
    
    // Get checker coordinates by dividing position by square size and flooring
    // Add scroll offset for animation
    float2 checker = floor((position + scrollOffset) / checkerSize);
    
    // Alternate between black and white by adding x and y checker coordinates
    // If the sum is even (mod 2 = 0), we get black (0.0)
    // If the sum is odd (mod 2 = 1), we get white (1.0)
    float pattern = fmod(checker.x + checker.y, 2.0);
    
    // Animate colors using time - subtle pastel colors
    // Base gray value for the checkerboard
    float gray = pattern * 0.8 + 0.1; // Range from 0.1 to 0.9 instead of 0 to 1
    
    // Add subtle color tinting that shifts over time
    // Using smaller amplitude (0.15) for gentle color variations
    float3 animatedColor = float3(
        gray + 0.15 * sin(time * 0.3),           // Slight red tint
        gray + 0.15 * sin(time * 0.3 + 2.094),   // Slight green tint (120 degrees)
        gray + 0.15 * sin(time * 0.3 + 4.189)    // Slight blue tint (240 degrees)
    );
    
    // Return the animated color
    // Alpha is always 1.0 (fully opaque)
    return float4(animatedColor, 1.0);
}

kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    // mainImage expects a backbuffer; pass iChannel0 so the legacy code
    // compiles even though this shader doesn't sample it. The channel
    // arg buffer is sized to at least 1 slot whenever we have any input.
    // For shaders with no inputs, we still synthesize a fallback texture
    // (see PhosphorRuntime), so this call is always valid.
    texture2d<float, access::read> backbuffer = channels.iChannel0;
    float4 color = mainImage(float2(gid), uniforms->resolution, uniforms->mouse,
                             uniforms->time, uniforms->frame, backbuffer);
    color.a = 1.0;
    outTexture.write(color, gid);
}
