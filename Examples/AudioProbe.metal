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

/// Visualizes the live microphone input.
///
/// - Top half: oscilloscope. The 1024-sample waveform drawn as a horizontal
///   trace, centered vertically. Amplitude controls vertical offset.
/// - Bottom half: spectrum analyzer. 512 FFT bins as vertical bars; low
///   frequencies on the left, high on the right; bar height = magnitude.
///
/// Pixels above/below 50% horizontal scan position dim toward black so the
/// graph reads cleanly over the dark background.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 p = float2(gid);
    float2 res = uniforms->resolution;
    float2 uv = p / res;

    // Background: subtle vertical gradient.
    float3 bg = mix(float3(0.02, 0.02, 0.06), float3(0.0, 0.0, 0.02), uv.y);
    float3 color = bg;

    // === Top half: waveform oscilloscope ===
    if (uv.y < 0.5) {
        // Map uv.x in [0, 1] to waveform index [0, 1023].
        uint idx = clamp(uint(uv.x * 1024.0), 0u, 1023u);
        float sample = uniforms->waveform[idx];
        // Center vertically in the top half, scale ±1 to roughly ±half-height.
        float wavY = 0.25 + sample * 0.20;
        float dist = abs(uv.y - wavY);
        // Thin glowing trace.
        float trace = exp(-dist * 200.0);
        color += float3(0.2, 1.0, 0.6) * trace;
    }

    // === Bottom half: spectrum bars ===
    if (uv.y >= 0.5) {
        float xInHalf = uv.x;
        uint bin = clamp(uint(xInHalf * 512.0), 0u, 511u);
        float mag = uniforms->spectrum[bin];
        // Bar height: 0 at uv.y = 1.0 (bottom of screen), grows upward.
        float barTop = 1.0 - mag * 0.5; // mag=1 -> bar tops out at vertical center
        // The bar covers vertical range [barTop, 1.0] in the lower half.
        if (uv.y > barTop) {
            // Color gradient: low frequencies cooler, high frequencies warmer.
            float3 hot = mix(float3(0.2, 0.4, 1.0), float3(1.0, 0.4, 0.2), xInHalf);
            color = hot * mag + bg * (1.0 - mag);
        }
    }

    // Mid-line separator.
    float midDist = abs(uv.y - 0.5);
    if (midDist < 0.002) {
        color = float3(0.3);
    }

    outTexture.write(float4(color, 1.0), gid);
}
