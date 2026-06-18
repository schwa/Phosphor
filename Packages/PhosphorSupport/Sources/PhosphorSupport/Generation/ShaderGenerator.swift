import FoundationModels
import FoundationModelBackends
import Foundation

/// Which Apple Intelligence backend to use for a generation request.
public enum GenerationModel: String, CaseIterable, Hashable, Sendable {
    /// On-device foundation model (`SystemLanguageModel.default`).
    case onDevice
    /// Apple's Private Cloud Compute foundation model. Higher capability,
    /// requires Apple Intelligence sign-in and connectivity, subject to
    /// per-app quotas.
    case privateCloudCompute
    /// Anthropic Claude Opus (via FoundationModelBackends). Requires an API
    /// key stored in the Keychain (see `KeychainAccount.anthropicAPIKey`).
    case anthropicClaudeOpus

    public var displayName: String {
        switch self {
        case .onDevice: "On Device"
        case .privateCloudCompute: "Private Cloud Compute"
        case .anthropicClaudeOpus: "Anthropic Claude Opus"
        }
    }

    /// True if this model is available without extra configuration (no API
    /// key required).
    public var requiresAPIKey: Bool {
        switch self {
        case .onDevice, .privateCloudCompute: return false
        case .anthropicClaudeOpus: return true
        }
    }
}

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
    ///
    /// If `existingSource` is non-empty the model is asked to *modify* the
    /// existing shader rather than produce a fresh one.
    public func generate(prompt: String, model: GenerationModel = .onDevice, existingSource: String = "") async throws -> String {
        let session: LanguageModelSession
        switch model {
        case .onDevice:
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.instructions
            )
        case .privateCloudCompute:
            session = LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: Self.instructions
            )
        case .anthropicClaudeOpus:
            guard let apiKey = KeychainStore.read(account: KeychainAccount.anthropicAPIKey),
                  !apiKey.isEmpty else {
                throw ShaderGeneratorError.missingAPIKey(.anthropicClaudeOpus)
            }
            let anthropic = AnthropicLanguageModel(
                apiKey: apiKey,
                model: "claude-opus-4-5"
            )
            session = LanguageModelSession(
                model: anthropic,
                instructions: Self.instructions
            )
        }
        let fullPrompt = Self.buildPrompt(userPrompt: prompt, existingSource: existingSource)
        let response = try await session.respond(
            to: fullPrompt,
            generating: GeneratedShader.self
        )
        let priorPrompts = PromptHistory.extract(from: existingSource)
        return try response.content.toMetalSource(prompts: priorPrompts + [prompt])
    }

    /// Combines the user's prompt with the current shader source (if any) into
    /// the message we hand to the model.
    private static func buildPrompt(userPrompt: String, existingSource: String) -> String {
        let trimmedSource = existingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { return userPrompt }
        return """
            The user has an existing Phosphor shader. Modify it according to their request, \
            keeping as much of the original structure as makes sense.

            ===== EXISTING SHADER =====
            \(trimmedSource)
            ===== END =====

            User request: \(userPrompt)
            """
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
        - `uniforms.resized` (uint) is 1 on the frame after the view resizes (textures are freshly
          zeroed). Feedback effects should re-seed when `uniforms.frame < 1.0 || uniforms.resized != 0u`.

        COORDINATE SYSTEM:
        - In Phosphor, `gid.y = 0` is at the TOP of the screen and `gid.y = resolution.y - 1`
          is at the bottom. This is opposite to GLSL / Shadertoy / WebGL.
        - If you write in the Phosphor convention (Y=0 at top), leave `flipY = false`.
        - If you write in GLSL/Shadertoy convention (Y=0 at bottom), set `flipY = true` and the
          runtime will flip the final blit vertically so the result is right-side up.
        - Be consistent: don't mix conventions in one shader.
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

        WHEN TO USE `inputs`:
        - Use `inputs` ONLY if your kernel calls `channels.iChannelN.read(...)` somewhere
          in its body. If you don't sample channels, `inputs` MUST be empty.
        - Procedural patterns (checkerboard, gradient, plasma, noise, fractals) do NOT need
          inputs — they compute their color from `gid` and `uniforms` only.
        - Feedback effects (Game of Life, fluid simulation, trails) DO need an input — the
          pass reads its own previous frame via `iChannel0` bound to its own ping-pong output.

        ===== EXAMPLE 1: solid red shader =====
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

        ===== EXAMPLE 2: checkerboard (procedural pattern, no inputs) =====
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
                uint cell = (gid.x / 32u) + (gid.y / 32u);
                float v = (cell % 2u == 0u) ? 1.0 : 0.0;
                outTexture.write(float4(v, v, v, 1.0), gid);
            }
            ```

        ===== EXAMPLE 3: animated gradient (uses uniforms.time, no inputs) =====
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
                float2 uv = float2(gid) / uniforms.resolution;
                float r = 0.5 + 0.5 * sin(uniforms.time + uv.x * 6.28);
                float g = 0.5 + 0.5 * sin(uniforms.time + uv.y * 6.28);
                outTexture.write(float4(r, g, 0.2, 1.0), gid);
            }
            ```

        SAMPLING CHANNELS (only if you declared inputs):
        - Use `channels.iChannel0.read(gid)` — returns a `float4`.
        - There is NO `.resource` member, NO `texture2d<...>(...)` constructor call.
        - Bad: `texture2d<float, access::read>(channels.iChannel0.resource, gid)`.
        - Good: `channels.iChannel0.read(gid)`.

        Keep kernels under ~80 lines. Do NOT write `#include` directives; the host adds them.

        MODIFICATION REQUESTS:
        If the user provides an existing shader together with their request, treat it as a
        modification: keep the existing structure and approach, change only what the user asks
        for. Output the complete updated shader (resources, passes, uniforms, full body) —
        we cannot apply partial edits.
    """
}

/// Errors that ``ShaderGenerator`` may raise before reaching the model.
public enum ShaderGeneratorError: Error, LocalizedError {
    case missingAPIKey(GenerationModel)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let model):
            return "Missing API key for \(model.displayName). Set it in Settings → Models."
        }
    }
}
