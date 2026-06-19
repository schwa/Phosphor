/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

[[resources]]
kind = "image"
id = "photo"
name = "screenshot"
access = "sample"

[[passes]]
id = "image"
output = "image"
inputs = [{ name = "iChannel0", resource = "photo" }]
*/

uint2 gid[[thread_position_in_grid]];

kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    device const Uniforms&          uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]]
)
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = float2(gid) / uniforms.resolution;
    float4 color = channels.iChannel0.sample(s, uv);
    outTexture.write(color, gid);
}
