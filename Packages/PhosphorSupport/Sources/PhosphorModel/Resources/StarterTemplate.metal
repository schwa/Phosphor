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

uint2 gid [[thread_position_in_grid]];

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    uniforms.textures.image.write(float4(uv.x, uv.y, 0.5 + 0.5 * sin(uniforms.time), 1.0), gid);
}
