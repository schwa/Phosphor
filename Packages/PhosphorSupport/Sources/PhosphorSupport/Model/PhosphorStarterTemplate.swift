import Foundation

/// Canonical starter shader for brand-new documents.
///
/// One source of truth shared by ``PhosphorMetalDocument`` and the
/// `.phosphord` bundle document so both doc types open at the same
/// hello-world. Also used by the Generate panel as the "untouched
/// template" sentinel for switching between fresh-generation and
/// modify-existing flows.
public enum PhosphorStarterTemplate {
    public static let source: String = """
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

        """
}
