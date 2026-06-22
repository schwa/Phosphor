/* phosphor:environment
output = "output"

[[textures]]
id = "output"
size = "drawable"
format = "rgba32Float"
init = { kind = "fill", color = [0.0, 0.0, 0.0, 1.0] }
swap = "none"

[[passes]]
id = "helloWorld"
textures = [
    { id = "output", access = "write" },
]
*/

/// Pulsing UV gradient. Simplest possible Phosphor shader: one pass, one
/// drawable-sized output texture, no other inputs.

uint2 gid [[thread_position_in_grid]];

kernel void helloWorld(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    float pulse = 0.5 + 0.5 * sin(uniforms.time);
    uniforms.textures.output.write(float4(uv.x, uv.y, pulse, 1.0), gid);
}
