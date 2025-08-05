#include <metal_stdlib>
using namespace metal;

// MARK: Helper functions


// MARK: Main kernel.

struct Uniforms {
    float time;
    float frame;
    float2 resolution;
    float2 mouse;
};

using SnippetFunction = float4(float2, float2, float2, float, float, texture2d<float, access::read>);

kernel void newComputeMain(
    texture2d<float, access::write> outTexture [[texture(0)]],
    texture2d<float, access::read> previousTexture [[texture(1)]],
    constant Uniforms& uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    visible_function_table<SnippetFunction> snippetFunctions [[buffer(1)]]
) {
    // Classic shader uniform names
    float2 resolution = uniforms.resolution;
    float2 mouse = uniforms.mouse;
    float time = uniforms.time;
    float frame = uniforms.frame;
    texture2d<float, access::read> backbuffer = previousTexture;
    float2 position = float2(gid);
    
    SnippetFunction *snippet = snippetFunctions[0];
    float4 color = snippet(position, resolution, mouse, time, frame, backbuffer);
    outTexture.write(color, gid);
}
