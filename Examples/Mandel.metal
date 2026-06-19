/* prompt: something involving fractals? */

/* phosphor:environment
output = "image"
uniforms = []

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
    format = "rgba16Float"
    initial = "zero"
    pingPong = false
    size = "drawable"*/

/// Renders an animated Mandelbrot fractal with smooth coloring.
/// Zooms into a visually interesting region over time.
/// No channel inputs needed - purely procedural.
kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms*          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    float2 res = uniforms->resolution;
    float2 uv = (float2(gid) - 0.5 * res) / min(res.x, res.y);
    
    // Animated zoom into an interesting region
    float t = uniforms->time * 0.15;
    float zoom = pow(1.5, t);
    float2 center = float2(-0.745, 0.186); // Interesting region
    
    float2 c = center + uv / zoom;
    float2 z = float2(0.0);
    
    float iter = 0.0;
    const float maxIter = 64.0;
    
    for (float i = 0.0; i < maxIter; i += 1.0) {
        // z = z^2 + c
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        
        if (dot(z, z) > 4.0) {
            iter = i;
            break;
        }
        iter = i;
    }
    
    // Smooth coloring using escape time algorithm
    float3 col = float3(0.0);
    
    if (iter < maxIter - 1.0) {
        // Smooth iteration count
        float sl = iter - log2(log2(dot(z, z))) + 4.0;
        sl = sl / maxIter;
        
        // Create vibrant color palette
        col.r = 0.5 + 0.5 * sin(3.0 + sl * 15.0 + uniforms->time * 0.5);
        col.g = 0.5 + 0.5 * sin(3.5 + sl * 15.0 + uniforms->time * 0.3);
        col.b = 0.5 + 0.5 * sin(4.0 + sl * 15.0 + uniforms->time * 0.7);
        
        // Boost contrast
        col = pow(col, float3(0.8));
    }
    
    outTexture.write(float4(col, 1.0), gid);
}
