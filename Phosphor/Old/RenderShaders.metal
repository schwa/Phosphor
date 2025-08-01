#include <metal_stdlib>
using namespace metal;

// Vertex shader for rendering a fullscreen quad
vertex float4 vertexShader(uint vertexID [[vertex_id]],
                          constant float2 *vertices [[buffer(0)]]) {
    return float4(vertices[vertexID], 0.0, 1.0);
}

// Fragment shader that samples from texture
fragment float4 fragmentShader(float4 position [[position]],
                             texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                    min_filter::linear);
    
    // Convert position to normalized texture coordinates
    // Flip Y coordinate to correct vertical orientation
    float2 texCoords = position.xy / float2(texture.get_width(), texture.get_height());
    texCoords.y = 1.0 - texCoords.y;
    
    return texture.sample(textureSampler, texCoords);
}
