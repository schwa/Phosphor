/* prompt: voxels */
/* prompt: there's weird jagged shit on the voxels */

/* phosphor:environment
flipY = true
output = "image"

[[passes]]
enabled = true
id = "image"
inputs = []
output = "image"

[[resources]]
id = "image"
kind = "texture2D"

    [resources.spec]
    flipTiming = "endOfFrame"
    format = "rgba32Float"
    initial = "zero"
    pingPong = false
    size = "drawable"

[[uniforms]]
default = 1.5
kind = "float"
name = "cameraHeight"

    [uniforms.ui.slider]
    max = 5.0
    min = 0.5

[[uniforms]]
default = 0.25
kind = "float"
name = "voxelSize"

    [uniforms.ui.slider]
    max = 1.0
    min = 0.1

[[uniforms]]
default = 0.04
kind = "float"
name = "fogDensity"

    [uniforms.ui.slider]
    max = 0.1
    min = 0.0*/

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

// Fractal brownian motion for terrain height
float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    float2 shift = float2(100.0);
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p = p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

// Get voxelized terrain height at position
float getHeight(float2 p, float voxelSize) {
    float h = fbm(p * 0.3) * 4.0;
    return floor(h / voxelSize) * voxelSize;
}

// Voxel color based on height
float3 getVoxelColor(float height) {
    if (height < 0.5) return float3(0.2, 0.4, 0.8); // Water
    if (height < 1.0) return float3(0.76, 0.7, 0.5); // Sand
    if (height < 2.0) return float3(0.2, 0.6, 0.2); // Grass
    if (height < 3.0) return float3(0.4, 0.35, 0.3); // Rock
    return float3(0.95, 0.95, 1.0); // Snow
}

// DDA-style voxel traversal for clean intersections
float4 rayMarchVoxels(float3 ro, float3 rd, float voxelSize, float fogDensity) {
    float maxDist = 50.0;
    
    // Current voxel position
    float3 voxel = floor(ro / voxelSize);
    
    // Step direction
    float3 step = sign(rd);
    
    // Distance to next voxel boundary in each axis
    float3 tDelta = abs(voxelSize / rd);
    
    // Initial distances to boundaries
    float3 tMax;
    tMax.x = (rd.x > 0.0) ? (voxel.x + 1.0) * voxelSize - ro.x : ro.x - voxel.x * voxelSize;
    tMax.y = (rd.y > 0.0) ? (voxel.y + 1.0) * voxelSize - ro.y : ro.y - voxel.y * voxelSize;
    tMax.z = (rd.z > 0.0) ? (voxel.z + 1.0) * voxelSize - ro.z : ro.z - voxel.z * voxelSize;
    tMax = tMax / abs(rd + 0.0001); // Avoid division by zero
    
    float t = 0.0;
    int lastAxis = 1; // Track which axis we stepped on (for normal)
    
    for (int i = 0; i < 256; i++) {
        if (t > maxDist) break;
        
        // Get terrain height at current voxel column
        float2 voxelPos = float2(voxel.x, voxel.z) * voxelSize;
        float terrainHeight = getHeight(voxelPos, voxelSize);
        float terrainVoxelY = floor(terrainHeight / voxelSize);
        
        // Check if current voxel is solid (below or at terrain height)
        if (voxel.y * voxelSize < terrainHeight) {
            // Calculate normal based on which face we entered
            float3 normal = float3(0.0);
            if (lastAxis == 0) normal.x = -step.x;
            else if (lastAxis == 1) normal.y = -step.y;
            else normal.z = -step.z;
            
            // Lighting
            float3 lightDir = normalize(float3(0.5, 0.8, 0.3));
            float diff = max(dot(normal, lightDir), 0.0);
            float amb = 0.3;
            
            float3 col = getVoxelColor(terrainHeight);
            col *= (amb + diff * 0.7);
            
            // Add fog
            float fog = 1.0 - exp(-t * fogDensity);
            float3 fogColor = float3(0.6, 0.7, 0.9);
            col = mix(col, fogColor, fog);
            
            return float4(col, 1.0);
        }
        
        // Step to next voxel - choose axis with smallest tMax
        if (tMax.x < tMax.y && tMax.x < tMax.z) {
            t = tMax.x;
            tMax.x += tDelta.x;
            voxel.x += step.x;
            lastAxis = 0;
        } else if (tMax.y < tMax.z) {
            t = tMax.y;
            tMax.y += tDelta.y;
            voxel.y += step.y;
            lastAxis = 1;
        } else {
            t = tMax.z;
            tMax.z += tDelta.z;
            voxel.z += step.z;
            lastAxis = 2;
        }
    }
    
    // Sky gradient
    float skyGrad = 0.5 + 0.5 * rd.y;
    float3 skyCol = mix(float3(0.6, 0.7, 0.9), float3(0.3, 0.5, 0.9), skyGrad);
    return float4(skyCol, 1.0);
}

/// Renders a procedural voxel terrain using DDA ray traversal.
/// Camera orbits around the scene, terrain colored by height (water, sand, grass, rock, snow).
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 uv = (float2(gid) - 0.5 * uniforms->resolution) / uniforms->resolution.y;
    
    float camHeight = userUniforms->cameraHeight;
    float voxelSize = userUniforms->voxelSize;
    float fogDensity = userUniforms->fogDensity;
    
    // Camera setup - orbiting around
    float angle = uniforms->time * 0.3;
    float3 ro = float3(sin(angle) * 10.0, camHeight + 3.0, cos(angle) * 10.0);
    float3 target = float3(0.0, 1.0, 0.0);
    
    // Camera matrix
    float3 forward = normalize(target - ro);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), forward));
    float3 up = cross(forward, right);
    
    float3 rd = normalize(uv.x * right + uv.y * up + 1.5 * forward);
    
    float4 col = rayMarchVoxels(ro, rd, voxelSize, fogDensity);
    
    outTexture.write(col, gid);
}
