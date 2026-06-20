/* phosphor:environment
output = "image"

[[textures]]
id = "image"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];



/// Renders a smiley face that opens and closes its mouth based on audio input.
/// Uses uniforms.spectrum[] for bass energy to control mouth opening,
/// and uniforms.waveform[] for subtle eye animation.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float aspect = res.x / res.y;
    float2 uv = float2(gid) / res;
    float t = uniforms.time;
    
    // Flip Y so bottom is 0
    uv.y = 1.0 - uv.y;
    
    // Correct for aspect ratio
    float2 p = uv - 0.5;
    p.x *= aspect;
    
    // === AUDIO ANALYSIS ===
    // Get bass energy for mouth movement
    float bass = 0.0;
    for (int i = 0; i < 32; i++) {
        bass += uniforms.spectrum[i];
    }
    bass = bass / 32.0;
    bass = pow(bass, 0.5) * 2.0;
    bass = clamp(bass, 0.0, 1.0);
    
    // Get mid frequencies for eye wiggle
    float mids = 0.0;
    for (int i = 64; i < 128; i++) {
        mids += uniforms.spectrum[i];
    }
    mids = mids / 64.0;
    
    float3 col = float3(0.1, 0.15, 0.25); // Background
    
    // === FACE CIRCLE ===
    float faceDist = length(p);
    float face = smoothstep(0.32, 0.31, faceDist);
    float3 faceColor = float3(1.0, 0.85, 0.2); // Yellow
    
    // Add shading to face
    float3 shadedFace = faceColor * (0.85 + 0.15 * (1.0 - p.y));
    col = mix(col, shadedFace, face);
    
    // Face outline
    float outline = smoothstep(0.32, 0.31, faceDist) - smoothstep(0.31, 0.30, faceDist);
    col = mix(col, float3(0.7, 0.5, 0.1), outline * 2.0);
    
    // === EYES ===
    float eyeY = 0.08 + mids * 0.01; // Slight bounce with mids
    float2 leftEyePos = float2(-0.12, eyeY);
    float2 rightEyePos = float2(0.12, eyeY);
    
    // Eye whites
    float leftEyeDist = length(p - leftEyePos);
    float rightEyeDist = length(p - rightEyePos);
    float eyeRadius = 0.055;
    
    float leftEye = smoothstep(eyeRadius, eyeRadius - 0.005, leftEyeDist);
    float rightEye = smoothstep(eyeRadius, eyeRadius - 0.005, rightEyeDist);
    col = mix(col, float3(1.0), leftEye);
    col = mix(col, float3(1.0), rightEye);
    
    // Pupils - slight movement with audio
    float2 pupilOffset = float2(sin(t * 2.0) * 0.01, cos(t * 1.5) * 0.005);
    float pupilRadius = 0.025;
    
    float leftPupilDist = length(p - leftEyePos - pupilOffset);
    float rightPupilDist = length(p - rightEyePos - pupilOffset);
    
    float leftPupil = smoothstep(pupilRadius, pupilRadius - 0.005, leftPupilDist);
    float rightPupil = smoothstep(pupilRadius, pupilRadius - 0.005, rightPupilDist);
    col = mix(col, float3(0.1, 0.1, 0.15), leftPupil);
    col = mix(col, float3(0.1, 0.1, 0.15), rightPupil);
    
    // Eye highlights
    float2 highlightOffset = float2(-0.012, 0.012);
    float highlightRadius = 0.008;
    float leftHighlight = smoothstep(highlightRadius, 0.0, length(p - leftEyePos - highlightOffset));
    float rightHighlight = smoothstep(highlightRadius, 0.0, length(p - rightEyePos - highlightOffset));
    col = mix(col, float3(1.0), leftHighlight * 0.8);
    col = mix(col, float3(1.0), rightHighlight * 0.8);
    
    // === MOUTH ===
    // Mouth opens based on bass energy
    float mouthOpen = bass * 0.12; // How wide mouth opens
    float2 mouthCenter = float2(0.0, -0.08);
    
    // Outer mouth (smile shape when closed, opens to oval)
    float2 mouthP = p - mouthCenter;
    
    // When closed: wide smile arc
    // When open: oval/circle shape
    float smileWidth = 0.15;
    float smileHeight = 0.04 + mouthOpen;
    
    // Ellipse for mouth opening
    float2 mouthScaled = float2(mouthP.x / smileWidth, mouthP.y / smileHeight);
    float mouthDist = length(mouthScaled);
    
    // Only show bottom half when closed, full oval when open
    float mouthMask = smoothstep(0.0, 0.3, bass); // Transition to open mouth
    float closedMouth = (mouthP.y < 0.0) ? 1.0 : 0.0;
    float openMouth = 1.0;
    float showMouth = mix(closedMouth, openMouth, mouthMask);
    
    float mouth = smoothstep(1.0, 0.95, mouthDist) * showMouth;
    
    // Mouth interior (dark)
    col = mix(col, float3(0.15, 0.05, 0.1), mouth);
    
    // Tongue when mouth is open
    if (bass > 0.2) {
        float2 tonguePos = float2(0.0, -0.12 - mouthOpen * 0.3);
        float2 tongueP = p - tonguePos;
        float tongueDist = length(float2(tongueP.x / 0.06, tongueP.y / 0.04));
        float tongue = smoothstep(1.0, 0.8, tongueDist) * step(p.y, mouthCenter.y);
        col = mix(col, float3(0.9, 0.4, 0.5), tongue * mouthMask);
    }
    
    // Teeth when mouth is partially open
    if (bass > 0.1 && bass < 0.7) {
        float teethY = mouthCenter.y + smileHeight * 0.5;
        float teeth = step(abs(p.x), 0.1) * step(abs(p.y - teethY), 0.015);
        teeth *= step(mouthCenter.y - smileHeight * 0.3, p.y);
        col = mix(col, float3(1.0), teeth * 0.8 * mouthMask);
    }
    
    // Smile line when mouth is closed
    float smileLine = smoothstep(0.008, 0.003, abs(mouthP.y + 0.02 - mouthP.x * mouthP.x * 2.0));
    smileLine *= step(abs(mouthP.x), smileWidth);
    smileLine *= (1.0 - mouthMask); // Fade out as mouth opens
    col = mix(col, float3(0.6, 0.4, 0.2), smileLine);
    
    // === CHEEKS (blush) ===
    float2 leftCheek = float2(-0.18, -0.02);
    float2 rightCheek = float2(0.18, -0.02);
    float blush = exp(-length(p - leftCheek) * 20.0) + exp(-length(p - rightCheek) * 20.0);
    blush *= (1.0 + bass * 0.5); // Blush more with audio
    col = mix(col, float3(1.0, 0.6, 0.5), blush * 0.3 * face);
    
    // === EYEBROWS ===
    // Bounce slightly with audio
    float browY = 0.16 + bass * 0.02;
    float2 leftBrow = float2(-0.12, browY);
    float2 rightBrow = float2(0.12, browY);
    
    float leftBrowDist = abs(p.y - leftBrow.y - (p.x - leftBrow.x) * 0.3);
    float rightBrowDist = abs(p.y - rightBrow.y + (p.x - rightBrow.x) * 0.3);
    
    float leftBrowLine = smoothstep(0.012, 0.005, leftBrowDist) * step(abs(p.x - leftBrow.x), 0.06);
    float rightBrowLine = smoothstep(0.012, 0.005, rightBrowDist) * step(abs(p.x - rightBrow.x), 0.06);
    
    col = mix(col, float3(0.5, 0.35, 0.1), leftBrowLine);
    col = mix(col, float3(0.5, 0.35, 0.1), rightBrowLine);
    
    // === GLOW EFFECT ===
    float glow = exp(-faceDist * 3.0) * (0.1 + bass * 0.2);
    col += glow * float3(1.0, 0.9, 0.3);
    
    // Vignette
    float vignette = 1.0 - length(uv - 0.5) * 0.6;
    col *= vignette;
    
    col = clamp(col, 0.0, 1.0);
    
    uniforms.textures.image.write(float4(col, 1.0), gid);
}

