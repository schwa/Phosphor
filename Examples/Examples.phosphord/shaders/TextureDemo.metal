/* phosphor:environment
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" }, { access = "read", id = "mandrill" } ]

[[textures]]
id = "mandrill"
init = { file = "mandrill", kind = "image" }

[[textures]]
format = "rgba8Unorm"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "none"
*/

uint2 gid [[thread_position_in_grid]];

/// Displays the mandrill.png texture by sampling it and writing to the output.
/// Reads from the mandrill texture resource and writes to the image output.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    // Bounds check
    if (gid.x >= uint(uniforms.resolution.x) || gid.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    // Read from the mandrill texture at the current pixel position
    float4 color = uniforms.textures.mandrill.read(gid);
    
    // Write to output
    uniforms.textures.image.write(color, gid);
}
