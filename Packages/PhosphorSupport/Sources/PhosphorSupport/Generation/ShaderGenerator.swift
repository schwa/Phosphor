import Foundation
import FoundationModelBackends
import FoundationModels
import Metal
import os

/// Which language model backend to use for a generation request.
///
/// `rawValue` is a stable string used by ``@AppStorage`` to persist the
/// user's choice across launches.
public enum GenerationModel: Hashable, Sendable {
    /// On-device foundation model (`SystemLanguageModel.default`).
    case onDevice
    /// Apple's Private Cloud Compute foundation model. Higher capability,
    /// requires Apple Intelligence sign-in and connectivity, subject to
    /// per-app quotas.
    case privateCloudCompute
    /// Anthropic Claude (any released model id). Requires an API key stored
    /// in the Keychain (see `KeychainAccount.anthropicAPIKey`).
    case anthropic(AnthropicModel)

    /// Stable string id for ``@AppStorage`` persistence.
    public var rawValue: String {
        switch self {
        case .onDevice: return "onDevice"
        case .privateCloudCompute: return "privateCloudCompute"
        case .anthropic(let model): return "anthropic.\(model.id)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "onDevice": self = .onDevice
        case "privateCloudCompute": self = .privateCloudCompute

        default:
            let prefix = "anthropic."
            guard rawValue.hasPrefix(prefix) else { return nil }
            let id = String(rawValue.dropFirst(prefix.count))
            guard let model = AnthropicModel.all.first(where: { $0.id == id }) else { return nil }
            self = .anthropic(model)
        }
    }

    public var displayName: String {
        switch self {
        case .onDevice: "On Device"
        case .privateCloudCompute: "Private Cloud Compute"
        case .anthropic(let model): "Anthropic \(model.displayName)"
        }
    }

    /// True if this model is available without extra configuration (no API
    /// key required).
    public var requiresAPIKey: Bool {
        switch self {
        case .onDevice, .privateCloudCompute: return false
        case .anthropic: return true
        }
    }

    /// All models the picker should offer, in display order.
    public static let all: [Self] =
        [.onDevice, .privateCloudCompute] + AnthropicModel.all.map { .anthropic($0) }
}

/// Curated catalogue of Anthropic models we offer through the Generate panel.
///
/// Anthropic releases and renames models frequently; keep this list up to
/// date manually. (#19 tracks the idea of fetching dynamically.)
public struct AnthropicModel: Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let opus = Self(id: "claude-opus-4-5", displayName: "Claude Opus 4.5")
    public static let sonnet = Self(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5")
    public static let haiku = Self(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5")

    public static let all: [Self] = [.opus, .sonnet, .haiku]
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

    /// Runs a generation: produces a ``GeneratedShader``, renders it to a
    /// full `.metal` source string, then attempts to compile it. If the
    /// initial output fails to compile, the model gets one automatic retry
    /// with the compiler errors as feedback.
    ///
    /// If `existingSource` is non-empty the model is asked to *modify* the
    /// existing shader rather than produce a fresh one.
    ///
    /// `progress`, if provided, is called on the main actor with phase
    /// updates so the UI can show what the generator is doing.
    @preconcurrency
    public func generate(
        prompt: String,
        model: GenerationModel = .onDevice,
        existingSource: String = "",
        progress: (@Sendable @MainActor (GenerationPhase) -> Void)? = nil
    ) async throws -> String {
        let session = try Self.makeSession(model: model)
        let priorPrompts = PromptHistory.extract(from: existingSource)
        let device = MTLCreateSystemDefaultDevice()

        // First attempt.
        await progress?(.generating)
        let initialPrompt = Self.buildPrompt(userPrompt: prompt, existingSource: existingSource)
        var generated = try await Self.respond(session: session, prompt: initialPrompt, model: model)
        Self.logGeneration(label: "initial", model: model, generated: generated)
        if generated.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ShaderGeneratorError.emptyBody(model)
        }
        var source = try generated.toMetalSource(prompts: priorPrompts + [prompt])

        // Compile check. If we don't have a device or the source has no
        // front-matter we can validate, just return as-is.
        guard let device else { return source }
        if let compileError = Self.tryCompile(source: source, device: device) {
            await progress?(.retrying(compileError: compileError))
            // One retry. The session retains history so the model already
            // knows what it just produced.
            let followUp = Self.buildRetryPrompt(compileError: compileError)
            generated = try await Self.respond(session: session, prompt: followUp, model: model)
            Self.logGeneration(label: "retry", model: model, generated: generated)
            if generated.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ShaderGeneratorError.emptyBody(model)
            }
            source = try generated.toMetalSource(prompts: priorPrompts + [prompt])
        }
        return source
    }

    /// Wraps `session.respond` so we can translate framework decode errors
    /// (e.g. the model omitted a required field) into our cleaner error
    /// surface, with the raw content logged for debugging.
    private static func respond(session: LanguageModelSession, prompt: String, model: GenerationModel) async throws -> GeneratedShader {
        do {
            return try await session.respond(to: prompt, generating: GeneratedShader.self).content
        } catch {
            logger.error("[respond] model=\(model.displayName, privacy: .public) decode failed: \(error, privacy: .public)")
            throw ShaderGeneratorError.malformedResponse(model: model, underlying: "\(error)")
        }
    }

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "generator")

    /// Logs what the model produced so we can debug why something looked wrong
    /// without losing the response.
    private static func logGeneration(label: String, model: GenerationModel, generated: GeneratedShader) {
        let bodyChars = generated.body.count
        let bodyHasKernel = generated.body.contains("kernel void")
        logger.info("""
            [\(label, privacy: .public)] model=\(model.displayName, privacy: .public) \
            title=\"\(generated.title, privacy: .public)\" \
            resources=\(generated.resources.count, privacy: .public) \
            passes=\(generated.passes.count, privacy: .public) \
            uniforms=\(generated.uniforms.count, privacy: .public) \
            flipY=\(generated.flipY, privacy: .public) \
            output=\"\(generated.outputResourceID, privacy: .public)\" \
            bodyChars=\(bodyChars, privacy: .public) \
            bodyHasKernel=\(bodyHasKernel, privacy: .public)
            """)
        if bodyChars == 0 {
            logger.error("[\(label, privacy: .public)] model returned empty body")
        } else {
            logger.debug("[\(label, privacy: .public)] body=\"\(generated.body, privacy: .public)\"")
        }
    }

    /// Constructs a session for the chosen backend.
    private static func makeSession(model: GenerationModel) throws -> LanguageModelSession {
        switch model {
        case .onDevice:
            return LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.instructions
            )

        case .privateCloudCompute:
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: Self.instructions
            )

        case .anthropic(let anthropicModel):
            guard let apiKey = KeychainStore.read(account: KeychainAccount.anthropicAPIKey),
                  !apiKey.isEmpty else {
                throw ShaderGeneratorError.missingAPIKey(model)
            }
            let anthropic = AnthropicLanguageModel(
                apiKey: apiKey,
                model: anthropicModel.id
            )
            return LanguageModelSession(
                model: anthropic,
                instructions: Self.instructions
            )
        }
    }

    /// Parses `source` for front-matter and tries to compile each declared
    /// pass. Returns a human-readable error string on the first failure, or
    /// nil if everything compiles (or if the source has no front-matter we
    /// can drive a compile from).
    private static func tryCompile(source: String, device: MTLDevice) -> String? {
        let parsed = ParsedPhosphorSource(source: source)
        guard let env = parsed.environment else { return nil }
        let compiler = PhosphorCompiler(device: device)
        do {
            let library = try compiler.compileLibrary(environment: env, userSource: parsed.body)
            for pass in env.passes where pass.enabled {
                _ = try compiler.makeFunction(library: library, for: pass.id)
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    private static func buildRetryPrompt(compileError: String) -> String {
        """
            The previous attempt failed to compile with these Metal compiler errors:

            \(compileError)

            Produce a complete updated shader that fixes the errors. Keep the same overall intent
            as the previous attempt, but make sure the kernel(s) compile cleanly. Common pitfalls
            to check: vector dimension mismatches in function calls (MSL is stricter than GLSL),
            undeclared identifiers, missing helper functions, integer vs float types in operations.
            """
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
                device const Uniforms*          uniforms       [[buffer(0)]],
                device const UserUniforms*      userUniforms   [[buffer(2)]],
                uint2 gid                                      [[thread_position_in_grid]])
            {
                // ... your code ...
                outTexture.write(float4(red, green, blue, alpha), gid);
            }

        Available inside a kernel (all read via `uniforms->`):
        - `time` (float): seconds since the document opened.
        - `timeDelta` (float): seconds elapsed since the previous frame.
        - `frame` (float): frame counter, starts at 0.
        - `resolution` (float2): drawable size in pixels.
        - `resized` (uint): 1 on the frame after the view resizes (textures freshly zeroed),
          0 otherwise. Feedback effects should re-seed when
          `uniforms->frame < 1.0 || uniforms->resized != 0u`.
        - `mouse` (float2): current cursor position in pixels. Updates on hover and drag.
        - `mouseButtons` (uint): bitmask of held buttons; bit 0 = left button. Use
          `uniforms->mouseButtons != 0u` to detect any press.
        - `mouseClickOrigin` (float2): cursor position in pixels at the start of the current
          press. Equal to `mouse` outside a drag.
        - `channelCount` (uint): how many `iChannelN` slots the environment declared.
          Rarely needed; informational only.
        - `waveform[i]` (i in 0..1023): live microphone audio samples in [-1, 1]. Zero when
          the user hasn't enabled the mic.
        - `spectrum[i]` (i in 0..511): linear FFT magnitudes in [0, 1], low frequencies first.
          Zero when the mic is off. Use this for audio-reactive shaders (level meters,
          beat-reactive glow, frequency-driven color).

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
                device const Uniforms*          uniforms       [[buffer(0)]],
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
                device const Uniforms*          uniforms       [[buffer(0)]],
                device const UserUniforms*      userUniforms   [[buffer(2)]],
                uint2 gid                                      [[thread_position_in_grid]])
            {
                uint cell = (gid.x / 32u) + (gid.y / 32u);
                float v = (cell % 2u == 0u) ? 1.0 : 0.0;
                outTexture.write(float4(v, v, v, 1.0), gid);
            }
            ```

        ===== EXAMPLE 3: animated gradient (uses uniforms->time, no inputs) =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            kernel void image(
                texture2d<float, access::write> outTexture     [[texture(0)]],
                device const ChannelBindings&   channels       [[buffer(1)]],
                device const Uniforms*          uniforms       [[buffer(0)]],
                device const UserUniforms*      userUniforms   [[buffer(2)]],
                uint2 gid                                      [[thread_position_in_grid]])
            {
                float2 uv = float2(gid) / uniforms->resolution;
                float r = 0.5 + 0.5 * sin(uniforms->time + uv.x * 6.28);
                float g = 0.5 + 0.5 * sin(uniforms->time + uv.y * 6.28);
                outTexture.write(float4(r, g, 0.2, 1.0), gid);
            }
            ```

        SAMPLING CHANNELS (only if you declared inputs):
        - Use `channels.iChannel0.read(gid)` — returns a `float4`.
        - There is NO `.resource` member, NO `texture2d<...>(...)` constructor call.
        - Bad: `texture2d<float, access::read>(channels.iChannel0.resource, gid)`.
        - Good: `channels.iChannel0.read(gid)`.

        MSL IS STRICTER THAN GLSL:
        - No implicit vector-dimension conversions. `noise3D(vec.xz)` does NOT work —
          `vec.xz` is a `float2` and `noise3D` takes a `float3`. You must explicitly
          construct a `float3`: `noise3D(float3(vec.xz, 0.0))`.
        - If you write a `noise3D` helper, call it ONLY with `float3` args. Write a
          separate `noise2D` helper if you need 2D noise (e.g. for terrain height).
        - Before calling any helper function, double-check the argument types match
          the parameter types exactly. The Metal compiler does NOT auto-promote
          float -> float2 -> float3 -> float4 the way GLSL does.
        - Keep raymarching loops bounded with a small max iteration count (≤64 is
          a safe upper bound). The GPU has a watchdog timer and will kill long
          dispatches.
        - Avoid producing NaN / inf in the output: clamp the final color to a
          sensible range, guard against divide-by-zero and log/sqrt of negative
          numbers.

        Keep kernels under ~80 lines. Do NOT write `#include` directives; the host adds them.

        DOCUMENT EACH KERNEL:
        Before every `kernel void` declaration, write a short documentation comment
        (one to three sentences) describing what the kernel does, which channels it
        reads, and what it writes. Use a /// or /** ... */ comment block. Multi-pass
        shaders document each kernel separately. Example:

            /// Steps Conway's Game of Life by one generation: reads the previous
            /// frame from iChannel0 and writes the next state into outTexture.
            kernel void image(
                ...

        MODIFICATION REQUESTS:
        If the user provides an existing shader together with their request, treat it as a
        modification: keep the existing structure and approach, change only what the user asks
        for. Output the complete updated shader (resources, passes, uniforms, full body) —
        we cannot apply partial edits.
    """
}

/// Reported by ``ShaderGenerator/generate(prompt:model:existingSource:progress:)``
/// so the UI can show what's happening during long generations.
public enum GenerationPhase: Hashable, Sendable {
    /// The model is producing its initial response.
    case generating
    /// The first response failed to compile; the model is being asked to fix it.
    case retrying(compileError: String)
}

/// Errors that ``ShaderGenerator`` may raise before reaching the model.
public enum ShaderGeneratorError: Error, LocalizedError {
    case missingAPIKey(GenerationModel)
    case emptyBody(GenerationModel)
    case malformedResponse(model: GenerationModel, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let model):
            return "Missing API key for \(model.displayName). Set it in Settings → Models."

        case .emptyBody(let model):
            return "\(model.displayName) returned a response with no kernel body. Try a different model or rephrase your prompt."

        case .malformedResponse(let model, let underlying):
            return "\(model.displayName) returned an incomplete response — try a different model or rephrase. (Details: \(underlying))"
        }
    }
}
