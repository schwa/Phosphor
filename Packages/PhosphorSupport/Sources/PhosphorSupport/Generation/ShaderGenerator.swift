import FoundationModels
import Foundation

/// Generates a Phosphor `.metal` source from a natural-language prompt via
/// Apple Intelligence (FoundationModels).
///
/// Use ``generate(prompt:)`` to run a single session and get back the
/// resulting source string. Errors propagate; the runtime can render the
/// returned string through ``PhosphorView/init?(source:)``, surfacing
/// compile and front-matter parse issues in its diagnostics overlay.
public struct ShaderGenerator {
    public init() {}

    /// Runs a one-shot generation: produces a ``GeneratedShader``, then
    /// renders it to a full `.metal` source string.
    public func generate(prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedShader.self
        )
        return try response.content.toMetalSource(prompt: prompt)
    }

    /// System prompt: explains what Phosphor is and what the model needs to produce.
    private static let instructions: String = """
        You generate Metal compute shaders for the Phosphor playground.

        ABSOLUTE RULES (do not violate any of these):
        - The `body` field MUST contain one or more functions starting with `kernel void`.
        - NEVER use `vertex`, `fragment`, `@vertex`, `@fragment`, or any non-compute shader.
        - NEVER reference resources you didn't declare in the `resources` field.
        - If your kernel doesn't sample any channel inputs, the `inputs` array MUST be empty.
        - For every resource you declare, set the `id`, `format`, and `pingPong` fields.

        Kernel signature (exact, copy verbatim, change only the name):

            kernel void <pass.id>(
                texture2d<float, access::write> outTexture     [[texture(0)]],
                device const ChannelBindings&   channels       [[buffer(1)]],
                constant Uniforms&              uniforms       [[buffer(0)]],
                device const UserUniforms*      userUniforms   [[buffer(2)]],
                uint2 gid                                      [[thread_position_in_grid]])
            {
                // ... your code ...
                outTexture.write(float4(red, green, blue, alpha), gid);
            }

        Available inside a kernel:
        - `uniforms.time` (float seconds), `uniforms.frame` (float), `uniforms.resolution` (float2).
        - `channels.iChannelN` (texture2d<float, access::read>) — only for channels you declared as inputs.
          Sample with `channels.iChannel0.read(gid)`.
        - `userUniforms->name` for each uniform you declared.
        - Math: sin, cos, mix, smoothstep, length, normalize, dot, cross, exp, pow, abs, clamp.

        Conventions:
        - Use `image` as the final output resource id. Use `bufA`, `bufB`, ... for intermediates.
        - `outputResourceID` must be the id of one of your resources (almost always `image`).
        - For a single-pass effect (most cases), declare ONE resource named `image` and ONE pass
          named `image` that writes to it.
        - For feedback effects (ping-pong, Game of Life style), set `pingPong = true` on the
          resource; the pass reads its own previous output via an `iChannel0` input bound to
          that same resource.

        Example for "solid red shader":
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            kernel void image(
                texture2d<float, access::write> outTexture     [[texture(0)]],
                device const ChannelBindings&   channels       [[buffer(1)]],
                constant Uniforms&              uniforms       [[buffer(0)]],
                device const UserUniforms*      userUniforms   [[buffer(2)]],
                uint2 gid                                      [[thread_position_in_grid]])
            {
                outTexture.write(float4(1.0, 0.0, 0.0, 1.0), gid);
            }
            ```

        Keep kernels under ~80 lines. Do NOT write `#include` directives; the host adds them.
    """
}
