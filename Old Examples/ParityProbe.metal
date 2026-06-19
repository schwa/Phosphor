/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "bufA"
spec = { size = "drawable", format = "rgba32Float", pingPong = true, flipTiming = "endOfFrame", initial = "zero" }

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

[[passes]]
id = "bufA"
output = "bufA"

[[passes]]
id = "image"
output = "image"
inputs = [{ name = "iChannel0", resource = "bufA" }]
*/

#include "Phosphor.h"

// bufA: writes a known value based on the frame counter. Red on even
// 30-frame periods, green on odd. Slow enough to see comfortably.
kernel void bufA(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    uint parity = (uint(uniforms->frame) / 30u) % 2u;
    float4 color = parity == 0u
        ? float4(1.0, 0.0, 0.0, 1.0)
        : float4(0.0, 1.0, 0.0, 1.0);
    outTexture.write(color, gid);
}

// image: sample bufA and write the sampled value to the screen.
//
// If channel parity is correct, the screen color matches bufA's current frame
// (i.e. red on even, green on odd). Visually: rapid red/green strobing.
//
// If channel parity is WRONG (#5), image reads last frame's bufA. The screen
// shows the opposite color, but since we strobe so fast, the visual result is
// indistinguishable. We compare in-shader instead: pure red, pure green, or
// BLUE if neither matches the expected current-frame parity.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float4 sampled = channels.iChannel0.read(gid);
    uint parity = (uint(uniforms->frame) / 30u) % 2u;
    float4 expected = parity == 0u
        ? float4(1.0, 0.0, 0.0, 1.0)
        : float4(0.0, 1.0, 0.0, 1.0);
    bool matches = (sampled.r == expected.r) && (sampled.g == expected.g);
    // Left half of screen: actual sampled color (so eye can see strobing).
    // Right half: diagnostic — yellow if matches expected, blue otherwise.
    if (gid.x < uint(uniforms->resolution.x) / 2u) {
        outTexture.write(sampled, gid);
    } else {
        float4 verdict = matches
            ? float4(1.0, 1.0, 0.0, 1.0)   // yellow = correct parity
            : float4(0.0, 0.0, 1.0, 1.0);  // blue = wrong parity (bug)
        outTexture.write(verdict, gid);
    }
}
