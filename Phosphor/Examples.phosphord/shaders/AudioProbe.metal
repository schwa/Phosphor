/* phosphor:environment
output = "image"

[[textures]]
id = "image"
swap = "endOfFrame"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
    { id = "image", access = "read", name = "feedback" },
]

[[uniforms]]
default = 1.0
kind = "float"
name = "gain"
ui = { slider = { min = 0.1, max = 5.0 } }

[[uniforms]]
default = 0.15
kind = "float"
name = "rainbowSpeed"
ui = { slider = { min = 0.0, max = 2.0 } }
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];


// Converts HSV to RGB. H in [0,1], S in [0,1], V in [0,1].
float3 hsv2rgb(float h, float s, float v) {
    float3 c = float3(h * 6.0, s, v);
    float3 rgb = clamp(abs(fmod(c.x + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return c.z * mix(float3(1.0), rgb, c.y);
}

/// Visualizes the live microphone input with adjustable gain and fading trails.
///
/// Uses ping-pong feedback to create persistence: reads the previous frame from
/// iChannel0, fades it toward the background, and draws the current waveform
/// and spectrum on top. This creates a ghostly trail effect where older traces
/// gradually disappear.
///
/// - Top section: circular oscilloscope with rainbow colors cycling over time.
/// - Middle section: linear waveform display underneath the ring.
/// - Bottom section: spectrum analyzer bars with fading trails.
///
/// The gain uniform amplifies both the waveform and spectrum display.
/// The rainbowSpeed uniform controls how fast the rainbow color cycles.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 p = float2(gid);
    float2 res = uniforms.resolution;
    float2 uv = p / res;
    
    float gain = userUniforms.gain;
    float rainbowSpeed = userUniforms.rainbowSpeed;
    float time = uniforms.time;

    // Background: subtle vertical gradient.
    float3 bg = mix(float3(0.02, 0.02, 0.06), float3(0.0, 0.0, 0.02), uv.y);
    
    // Read previous frame and fade it toward background.
    float3 prevColor = uniforms.textures.feedback.read(gid).rgb;
    
    // Fade factor: controls how quickly trails disappear.
    float fade = 0.92;
    
    // Blend previous frame toward background.
    float3 color = mix(bg, prevColor, fade);
    
    // Reset on first frame or resize.
    if (uniforms.frame < 1.0 || uniforms.resized != 0u) {
        color = bg;
    }

    // Layout: top 35% for ring, 35%-50% for linear waveform, 50%-100% for spectrum
    float ringBottom = 0.35;
    float linearBottom = 0.50;

    // === Top section: circular waveform oscilloscope with rainbow ===
    if (uv.y < ringBottom) {
        // Center of the circle in the top section.
        float2 center = float2(0.5, ringBottom * 0.5);
        float2 fromCenter = uv - center;
        
        // Adjust aspect ratio so circle isn't stretched.
        float aspect = res.x / res.y;
        fromCenter.x *= aspect;
        
        float dist = length(fromCenter);
        float angle = atan2(fromCenter.y, fromCenter.x);
        
        // Map angle from [-pi, pi] to [0, 1] for waveform index.
        float angleNorm = (angle + 3.14159265) / (2.0 * 3.14159265);
        uint idx = clamp(uint(angleNorm * 1024.0), 0u, 1023u);
        float sample = uniforms.waveform[idx] * gain;
        
        // Base radius of the circle, with waveform modulating it.
        float baseRadius = 0.12;
        float waveRadius = baseRadius + sample * 0.06;
        
        // Distance from the waveform ring.
        float ringDist = abs(dist - waveRadius);
        
        // Rainbow color: hue cycles purely based on time, speed controlled by slider.
        float hue = fract(time * rainbowSpeed);
        float3 rainbowColor = hsv2rgb(hue, 0.9, 0.85);
        
        // Glowing trace - reduced intensity to prevent white glare.
        float trace = exp(-ringDist * 400.0) * 0.7;
        color += rainbowColor * trace;
        
        // Add softer outer glow with slightly shifted hue - also reduced.
        float outerGlow = exp(-ringDist * 100.0) * 0.2;
        float3 glowColor = hsv2rgb(fract(hue + 0.1), 0.8, 0.7);
        color += glowColor * outerGlow;
        
        // Clamp to prevent oversaturation/white-out.
        color = min(color, float3(1.0));
    }

    // === Middle section: linear waveform underneath the ring ===
    if (uv.y >= ringBottom && uv.y < linearBottom) {
        // Map x position to waveform sample index.
        uint idx = clamp(uint(uv.x * 1024.0), 0u, 1023u);
        float sample = uniforms.waveform[idx] * gain;
        
        // Normalize y within this section: 0 at top, 1 at bottom.
        float yInSection = (uv.y - ringBottom) / (linearBottom - ringBottom);
        
        // Center line is at yInSection = 0.5, waveform oscillates around it.
        float centerY = 0.5;
        float waveY = centerY - sample * 0.4; // Invert so positive samples go up
        
        // Distance from the waveform line.
        float waveDist = abs(yInSection - waveY);
        
        // Rainbow color matching the ring, same time-based hue.
        float hue = fract(time * rainbowSpeed);
        float3 rainbowColor = hsv2rgb(hue, 0.9, 0.85);
        
        // Glowing trace for the linear waveform.
        float trace = exp(-waveDist * 80.0) * 0.7;
        color += rainbowColor * trace;
        
        // Softer glow.
        float outerGlow = exp(-waveDist * 20.0) * 0.2;
        float3 glowColor = hsv2rgb(fract(hue + 0.1), 0.8, 0.7);
        color += glowColor * outerGlow;
        
        // Clamp to prevent oversaturation.
        color = min(color, float3(1.0));
    }

    // === Bottom section: spectrum bars ===
    if (uv.y >= linearBottom) {
        // Remap uv.y so the spectrum fills the bottom section.
        float yInSpectrum = (uv.y - linearBottom) / (1.0 - linearBottom);
        
        float xInHalf = uv.x;
        uint bin = clamp(uint(xInHalf * 512.0), 0u, 511u);
        float mag = uniforms.spectrum[bin] * gain;
        
        // Aggressive power curve to massively boost weaker signals.
        float magBoosted = pow(mag, 0.25);
        // Additional multiplicative boost.
        magBoosted *= 2.0;
        // Clamp after boost for display.
        float magClamped = clamp(magBoosted, 0.0, 1.0);
        
        // Bar height: 0 at bottom of section, grows upward.
        float barTop = 1.0 - magClamped;
        
        // The bar covers vertical range [barTop, 1.0] in the spectrum section.
        if (yInSpectrum > barTop) {
            // Color gradient: low frequencies cooler, high frequencies warmer.
            float3 hot = mix(float3(0.3, 0.6, 1.0), float3(1.0, 0.4, 0.1), xInHalf);
            float barIntensity = (yInSpectrum - barTop) / (1.0 - barTop);
            barIntensity = 1.0 - barIntensity * 0.2;
            // Additive blend for trail effect.
            color = max(color, hot * (1.0 + 0.8 * magClamped) * barIntensity);
        }
        
        // Add stronger glow above the bars.
        float glowDist = barTop - yInSpectrum;
        if (glowDist > 0.0 && glowDist < 0.15) {
            float3 hot = mix(float3(0.3, 0.6, 1.0), float3(1.0, 0.4, 0.1), xInHalf);
            float glow = exp(-glowDist * 20.0) * magClamped * 1.2;
            color += hot * glow;
        }
        
        // Add secondary bloom/halo effect.
        if (glowDist > 0.0 && glowDist < 0.25) {
            float3 hot = mix(float3(0.2, 0.4, 0.8), float3(0.8, 0.2, 0.05), xInHalf);
            float bloom = exp(-glowDist * 10.0) * magClamped * 0.4;
            color += hot * bloom;
        }
    }

    // Separator lines.
    float ringLineDist = abs(uv.y - ringBottom);
    float linearLineDist = abs(uv.y - linearBottom);
    if (ringLineDist < 0.002 || linearLineDist < 0.002) {
        color = float3(0.3);
    }

    uniforms.textures.image.write(float4(color, 1.0), gid);
}
