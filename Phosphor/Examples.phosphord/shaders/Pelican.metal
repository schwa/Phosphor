/* phosphor:environment
output = "image"

[[textures]]
id = "image"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]

[[uniforms]]
default = 3.0
kind = "float"
name = "pedalSpeed"
ui = { slider = { min = 0.5, max = 10.0 } }

[[uniforms]]
default = 1.0
kind = "float"
name = "pelicanScale"
ui = { slider = { min = 0.5, max = 2.0 } }

[[uniforms]]
default = [ 0.2, 0.2, 0.3, 1.0 ]
kind = "color"
name = "bikeColor"
ui = "color"

[[uniforms]]
default = [ 1.0, 0.95, 0.9, 1.0 ]
kind = "color"
name = "pelicanColor"
ui = "color"

[[uniforms]]
default = [ 1.0, 0.7, 0.3, 1.0 ]
kind = "color"
name = "beakColor"
ui = "color"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];


// Signed distance functions for shapes
float sdCircle(float2 p, float r) {
    return length(p) - r;
}

float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdEllipse(float2 p, float2 ab) {
    p = abs(p);
    if (p.x > p.y) { p = p.yx; ab = ab.yx; }
    float l = ab.y * ab.y - ab.x * ab.x;
    float m = ab.x * p.x / l;
    float n = ab.y * p.y / l;
    float m2 = m * m;
    float n2 = n * n;
    float c = (m2 + n2 - 1.0) / 3.0;
    float c3 = c * c * c;
    float q = c3 + m2 * n2 * 2.0;
    float d = c3 + m2 * n2;
    float g = m + m * n2;
    float co;
    if (d < 0.0) {
        float h = acos(q / c3) / 3.0;
        float s = cos(h);
        float t = sin(h) * sqrt(3.0);
        float rx = sqrt(-c * (s + t + 2.0) + m2);
        float ry = sqrt(-c * (s - t + 2.0) + m2);
        co = (ry + sign(l) * rx + abs(g) / (rx * ry) - m) / 2.0;
    } else {
        float h = 2.0 * m * n * sqrt(d);
        float s = sign(q + h) * pow(abs(q + h), 1.0 / 3.0);
        float u = sign(q - h) * pow(abs(q - h), 1.0 / 3.0);
        float rx = -s - u - c * 4.0 + 2.0 * m2;
        float ry = (s - u) * sqrt(3.0);
        float rm = sqrt(rx * rx + ry * ry);
        co = (ry / sqrt(rm - rx) + 2.0 * g / rm - m) / 2.0;
    }
    float2 r = ab * float2(co, sqrt(1.0 - co * co));
    return length(r - p) * sign(p.y - r.y);
}

float sdLine(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

float opUnion(float d1, float d2) { return min(d1, d2); }
float opSubtract(float d1, float d2) { return max(-d1, d2); }

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = (float2(gid) - 0.5 * uniforms.resolution) / uniforms.resolution.y;
    uv.y = -uv.y;
    float t = uniforms.time;
    
    // User uniforms
    float pedalSpeed = userUniforms.pedalSpeed;
    float scale = userUniforms.pelicanScale;
    float3 bikeCol = userUniforms.bikeColor.rgb;
    float3 pelCol = userUniforms.pelicanColor.rgb;
    float3 beakCol = userUniforms.beakColor.rgb;
    
    // Animation - pedaling motion
    float pedal = sin(t * pedalSpeed) * 0.03;
    float bounce = abs(sin(t * pedalSpeed)) * 0.01;
    
    // Bicycle wheels
    float2 wheelBack = float2(-0.15, -0.25);
    float2 wheelFront = float2(0.15, -0.25);
    float wheelR = 0.1;
    
    float d = sdCircle(uv - wheelBack, wheelR);
    d = opUnion(d, sdCircle(uv - wheelFront, wheelR));
    d = opSubtract(sdCircle(uv - wheelBack, wheelR - 0.012), d);
    d = opSubtract(sdCircle(uv - wheelFront, wheelR - 0.012), d);
    
    // Spokes
    for (int i = 0; i < 6; i++) {
        float angle = float(i) * 3.14159 / 3.0 + t * pedalSpeed;
        float2 dir = float2(cos(angle), sin(angle)) * wheelR;
        d = opUnion(d, sdLine(uv, wheelBack, wheelBack + dir, 0.003));
        d = opUnion(d, sdLine(uv, wheelFront, wheelFront + dir, 0.003));
    }
    
    // Frame
    float2 seat = float2(-0.05, -0.1 + bounce);
    float2 handlebar = float2(0.12, -0.05 + bounce);
    d = opUnion(d, sdLine(uv, wheelBack, seat, 0.008));
    d = opUnion(d, sdLine(uv, seat, float2(0.0, -0.2), 0.008));
    d = opUnion(d, sdLine(uv, float2(0.0, -0.2), wheelFront, 0.008));
    d = opUnion(d, sdLine(uv, float2(0.0, -0.2), handlebar, 0.008));
    d = opUnion(d, sdLine(uv, handlebar, handlebar + float2(0.03, 0.0), 0.006));
    
    // Seat
    d = opUnion(d, sdBox(uv - seat - float2(0.0, 0.02), float2(0.04, 0.015)));
    
    // Pelican body (scaled)
    float2 bodyPos = float2(-0.02, 0.08 + bounce);
    float bodyD = sdEllipse((uv - bodyPos) / scale, float2(0.12, 0.1)) * scale;
    d = opUnion(d, bodyD);
    
    // Pelican head (scaled)
    float2 headPos = float2(0.1 * scale, 0.2 * scale + bounce);
    float headD = sdCircle(uv - headPos, 0.06 * scale);
    d = opUnion(d, headD);
    
    // Pelican beak (scaled)
    float2 beakPos = float2(0.2 * scale, 0.15 * scale + bounce);
    float beakD = sdEllipse((uv - beakPos) / scale, float2(0.1, 0.05)) * scale;
    d = opUnion(d, beakD);
    d = opUnion(d, sdLine(uv, headPos + float2(0.04 * scale, -0.01 * scale), beakPos + float2(0.08 * scale, 0.02 * scale), 0.012 * scale));
    
    // Eye
    float eye = sdCircle(uv - headPos - float2(0.02 * scale, 0.015 * scale), 0.015 * scale);
    
    // Pelican legs on pedals
    float2 pedalPos = float2(0.0, -0.2);
    d = opUnion(d, sdLine(uv, bodyPos - float2(0.03, 0.08), pedalPos + float2(pedal, 0.0), 0.015));
    d = opUnion(d, sdLine(uv, bodyPos - float2(0.0, 0.08), pedalPos + float2(-pedal, 0.0), 0.015));
    
    // Feet on pedals
    d = opUnion(d, sdEllipse(uv - pedalPos - float2(pedal, -0.02), float2(0.03, 0.015)));
    d = opUnion(d, sdEllipse(uv - pedalPos - float2(-pedal, -0.02), float2(0.03, 0.015)));
    
    // Wing (scaled)
    float2 wingPos = bodyPos + float2(-0.05 * scale, 0.02 * scale);
    float wingD = sdEllipse((uv - wingPos) / scale, float2(0.08, 0.04)) * scale;
    d = opUnion(d, wingD);
    
    // Coloring
    float3 skyColor = float3(0.5, 0.8, 1.0);
    float3 groundColor = float3(0.3, 0.6, 0.3);
    
    // Background gradient
    float3 col = mix(groundColor, skyColor, smoothstep(-0.3, 0.0, uv.y));
    
    // Draw pelican and bike
    col = mix(col, bikeCol, 1.0 - smoothstep(0.0, 0.008, d));
    col = mix(col, pelCol, 1.0 - smoothstep(0.0, 0.008, sdEllipse((uv - bodyPos) / scale, float2(0.12, 0.1)) * scale));
    col = mix(col, pelCol, 1.0 - smoothstep(0.0, 0.008, sdCircle(uv - headPos, 0.06 * scale)));
    col = mix(col, beakCol, 1.0 - smoothstep(0.0, 0.008, sdEllipse((uv - beakPos) / scale, float2(0.1, 0.05)) * scale));
    col = mix(col, float3(0.0), 1.0 - smoothstep(0.0, 0.005, eye));
    col = mix(col, pelCol, 1.0 - smoothstep(0.0, 0.008, sdEllipse((uv - wingPos) / scale, float2(0.08, 0.04)) * scale));
    
    uniforms.textures.image.write(float4(col, 1.0), gid);
}
