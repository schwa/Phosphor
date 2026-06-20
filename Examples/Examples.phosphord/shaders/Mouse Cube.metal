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



/// Renders a 3D wireframe cube that rotates based on mouse position.
/// Moving the mouse horizontally rotates around Y, vertically rotates around X.
/// No inputs needed - purely procedural.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 res = uniforms.resolution;
    float2 uv = (float2(gid) - 0.5 * res) / res.y;
    
    // Mouse-controlled rotation: map mouse position to rotation angles
    float2 mouse = uniforms.mouse / res;
    float angleY = (mouse.x - 0.5) * 6.28; // Full rotation range horizontally
    float angleX = (mouse.y - 0.5) * 3.14; // Half rotation range vertically
    
    float cosY = cos(angleY);
    float sinY = sin(angleY);
    float cosX = cos(angleX);
    float sinX = sin(angleX);
    
    float3 col = float3(0.02, 0.02, 0.05); // background
    
    // Cube vertices (smaller cube - scaled down by 0.5)
    float3 vertices[8] = {
        float3(-0.5, -0.5, -0.5), float3( 0.5, -0.5, -0.5),
        float3( 0.5,  0.5, -0.5), float3(-0.5,  0.5, -0.5),
        float3(-0.5, -0.5,  0.5), float3( 0.5, -0.5,  0.5),
        float3( 0.5,  0.5,  0.5), float3(-0.5,  0.5,  0.5)
    };
    
    // Cube edges (pairs of vertex indices)
    int edges[24] = {
        0,1, 1,2, 2,3, 3,0,  // front face
        4,5, 5,6, 6,7, 7,4,  // back face
        0,4, 1,5, 2,6, 3,7   // connecting edges
    };
    
    // Transform vertices
    for (int i = 0; i < 8; i++) {
        float3 v = vertices[i];
        // Rotate around Y
        float x1 = v.x * cosY - v.z * sinY;
        float z1 = v.x * sinY + v.z * cosY;
        v.x = x1;
        v.z = z1;
        // Rotate around X
        float y1 = v.y * cosX - v.z * sinX;
        float z2 = v.y * sinX + v.z * cosX;
        v.y = y1;
        v.z = z2;
        vertices[i] = v;
    }
    
    // Draw edges
    for (int i = 0; i < 12; i++) {
        float3 p1 = vertices[edges[i*2]];
        float3 p2 = vertices[edges[i*2+1]];
        
        // Project to 2D
        float scale = 2.0;
        float2 a = p1.xy * scale / (p1.z + 4.0);
        float2 b = p2.xy * scale / (p2.z + 4.0);
        
        // Distance from point to line segment
        float2 pa = uv - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float d = length(pa - ba * h);
        
        // Depth-based color (brighter when closer)
        float depth = mix(p1.z, p2.z, h);
        float brightness = 1.0 - (depth + 1.0) * 0.25;
        brightness = clamp(brightness, 0.3, 1.0);
        
        // Edge glow
        float edge = smoothstep(0.015, 0.005, d);
        float3 edgeColor = float3(0.3, 0.7, 1.0) * brightness;
        col = mix(col, edgeColor, edge);
        
        // Extra glow
        float glow = 0.003 / (d + 0.001);
        col += float3(0.1, 0.3, 0.5) * glow * brightness * 0.15;
    }
    
    // Draw vertices as bright points
    for (int i = 0; i < 8; i++) {
        float3 v = vertices[i];
        float2 p = v.xy * 2.0 / (v.z + 4.0);
        float d = length(uv - p);
        float brightness = 1.0 - (v.z + 1.0) * 0.25;
        brightness = clamp(brightness, 0.4, 1.0);
        float point = smoothstep(0.025, 0.015, d);
        col = mix(col, float3(1.0, 1.0, 1.0) * brightness, point);
    }
    
    col = clamp(col, 0.0, 1.0);
    uniforms.textures.image.write(float4(col, 1.0), gid);
}

