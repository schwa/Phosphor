/* phosphor:environment
output = "image"

[[textures]]
id = "image"
format = "rgba16Float"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]

[[uniforms]]
default = 0.3
kind = "float"
name = "sunHeight"
ui = { slider = { min = -0.2, max = 1.0 } }

[[uniforms]]
default = 0.5
kind = "float"
name = "fogDensity"
ui = { slider = { min = 0.0, max = 1.0 } }

[[uniforms]]
default = [ 0.4, 0.6, 0.9, 1.0 ]
kind = "color"
name = "skyColor"
ui = "color"

[[uniforms]]
default = [ 0.2, 0.5, 0.15, 1.0 ]
kind = "color"
name = "terrainColor"
ui = "color"
*/

#include "Phosphor.h"

uint2 gid [[thread_position_in_grid]];




// Simple hash for noise
float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Value noise
float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Fractal Brownian motion for terrain
float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 6; i++) {
        value += amplitude * noise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

// Terrain height function
float terrain(float2 p) {
    return fbm(p * 0.3) * 2.0 - 0.5;
}

// Raymarching the terrain
float raymarchTerrain(float3 ro, float3 rd, float tMin, float tMax) {
    float t = tMin;
    for (int i = 0; i < 80; i++) {
        float3 p = ro + rd * t;
        float h = terrain(p.xz);
        if (p.y < h) return t;
        t += max(0.01, (p.y - h) * 0.4);
        if (t > tMax) break;
    }
    return -1.0;
}

// Calculate terrain normal
float3 calcNormal(float3 p) {
    float2 e = float2(0.01, 0.0);
    return normalize(float3(
        terrain(p.xz - e.xy) - terrain(p.xz + e.xy),
        2.0 * e.x,
        terrain(p.xz - e.yx) - terrain(p.xz + e.yx)
    ));
}

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    // Flip the Y coordinate to correct the upside-down rendering
    float2 flippedGid = float2(gid.x, uniforms.resolution.y - 1.0 - float(gid.y));
    float2 uv = (flippedGid - 0.5 * uniforms.resolution) / uniforms.resolution.y;
    
    float sunH = userUniforms.sunHeight;
    float fogD = userUniforms.fogDensity;
    float3 skyCol = userUniforms.skyColor.rgb;
    float3 terrainCol = userUniforms.terrainColor.rgb;
    
    // Camera setup - slowly moving forward
    float camTime = uniforms.time * 0.5;
    float3 ro = float3(camTime, 1.5, camTime * 0.5);
    float3 target = ro + float3(1.0, -0.1, 0.5);
    
    float3 forward = normalize(target - ro);
    float3 right = normalize(cross(float3(0, 1, 0), forward));
    float3 up = cross(forward, right);
    float3 rd = normalize(uv.x * right + uv.y * up + 1.5 * forward);
    
    // Sun direction
    float3 sunDir = normalize(float3(0.8, sunH + 0.3, 0.4));
    
    // Sky gradient
    float3 col = mix(skyCol * 1.2, skyCol * 0.5, pow(max(0.0, rd.y), 0.5));
    
    // Sun
    float sunDot = dot(rd, sunDir);
    col += float3(1.0, 0.9, 0.7) * pow(max(0.0, sunDot), 64.0);
    col += float3(1.0, 0.7, 0.4) * pow(max(0.0, sunDot), 8.0) * 0.3;
    
    // Raymarch terrain
    float t = raymarchTerrain(ro, rd, 0.1, 100.0);
    
    if (t > 0.0) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p);
        
        // Lighting
        float diff = max(0.0, dot(n, sunDir));
        float amb = 0.3 + 0.2 * n.y;
        
        // Terrain coloring based on height and slope
        float h = terrain(p.xz);
        float slope = 1.0 - n.y;
        
        float3 grass = terrainCol;
        float3 rock = float3(0.4, 0.35, 0.3);
        float3 snow = float3(0.95, 0.95, 1.0);
        
        float3 terrainC = mix(grass, rock, smoothstep(0.4, 0.7, slope));
        terrainC = mix(terrainC, snow, smoothstep(0.8, 1.2, h));
        
        col = terrainC * (amb + diff * 0.7);
        
        // Fog
        float fog = 1.0 - exp(-t * fogD * 0.03);
        col = mix(col, skyCol * 0.8, fog);
    }
    
    // Tone mapping and gamma
    col = col / (col + 1.0);
    col = pow(col, float3(0.45));
    
    uniforms.textures.image.write(float4(col, 1.0), gid);
}


