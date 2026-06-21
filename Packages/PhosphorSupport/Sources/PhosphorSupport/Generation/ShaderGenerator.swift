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
            let apiKey: String
            switch KeychainStore.readResult(account: KeychainAccount.anthropicAPIKey) {
            case .found(let value) where !value.isEmpty:
                apiKey = value
            case .found, .notFound:
                throw ShaderGeneratorError.missingAPIKey(model)
            case .failed(let status):
                // Transient keychain failure — the key may well be set. Report
                // it distinctly so the user retries instead of re-entering it.
                throw ShaderGeneratorError.keychainReadFailed(model: model, status: status)
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
        guard let config = parsed.configuration else { return nil }
        let compiler = PhosphorCompiler(device: device)
        do {
            let library = try compiler.compileLibrary(configuration: config, userSource: parsed.body)
            for pass in config.passes where pass.enabled {
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
    ///
    /// Schema note: the `@Generable` schema (resources / passes / inputs /
    /// outputResourceID) is the *Foundation-Models-visible* contract. The
    /// runtime model is different (textures + per-binding access). The host
    /// adapter inside `GeneratedShader.toPhosphorConfiguration()` synthesizes
    /// the binding list automatically: each pass gets a `write` binding for
    /// its declared `output` plus a `read` binding for each declared input.
    /// The model should keep producing the schema fields; the kernel-side
    /// MSL is what changed.
    private static let instructions: String = """
        You generate Metal compute shaders for the Phosphor playground.

        ABSOLUTE RULES (do not violate any of these):
        - The `body` field MUST contain one or more functions starting with `kernel void`.
        - NEVER use `vertex`, `fragment`, `@vertex`, `@fragment`, or any non-compute shader.
        - NEVER reference resources you didn't declare in the `resources` field.
        - If your kernel doesn't sample any channel inputs, the `inputs` array MUST be empty.
        - For every resource you declare, set the `id`, `format`, and `pingPong` fields.

        KERNEL SIGNATURE (exact — copy this and change only the function name):

            uint2 gid [[thread_position_in_grid]];

            kernel void <pass.id>(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                // ... your code ...
                uniforms.textures.<output_id>.write(float4(r, g, b, a), gid);
            }

        Notes on the signature:
        - `gid` is a FILE-SCOPE global with the `[[thread_position_in_grid]]` attribute,
          declared ONCE at the top of the body — not a kernel parameter. Repeat the same
          single declaration in your body.
        - `Uniforms` is a per-pass argument buffer that carries built-in scalars/audio
          AND a nested `textures` struct (one field per texture the pass declares).
          Access fields with `uniforms.time`, `uniforms.resolution`, etc. — dot, not arrow.
        - `UserUniforms` is a separate argument buffer at buffer(1). Access with
          `userUniforms.<name>`, also dot, not arrow.
        - The pass writes through `uniforms.textures.<output_id>.write(color, gid)`.
          The field name inside `textures` matches the resource id (so if the output
          resource is `image`, you write `uniforms.textures.image.write(...)`).

        UNIFORMS FIELDS (read via `uniforms.<field>`):
        - `time` (float): seconds since the document opened.
        - `timeDelta` (float): seconds elapsed since the previous frame.
        - `frame` (float): frame counter, starts at 0.
        - `resolution` (float2): drawable size in pixels.
        - `resized` (uint): 1 on the frame after the view resizes; 0 otherwise. Feedback
          effects should re-seed when `uniforms.frame < 1.0 || uniforms.resized != 0u`.
        - `mouse` (float2): current cursor position in pixels.
        - `mouseButtons` (uint): bitmask of held buttons; bit 0 = left button.
        - `mouseClickOrigin` (float2): cursor position at the start of the current press.
        - `waveform[i]` (float, i in 0..1023): live microphone time-domain samples in [-1, 1].
          Access via `uniforms.waveform[i]`. Zero when the mic is off.
        - `spectrum[i]` (float, i in 0..511): linear FFT magnitudes in [0, 1], low
          frequencies first. Access via `uniforms.spectrum[i]`. Zero when the mic is off.

        COORDINATE SYSTEM:
        - In Phosphor, `gid.y = 0` is at the TOP of the screen.
        - If you write in Phosphor convention (Y=0 at top), leave `flipY = false`.
        - If you write in GLSL/Shadertoy convention (Y=0 at bottom), set `flipY = true`.
        - Be consistent within one shader.

        SAMPLING CHANNEL INPUTS:
        - The host synthesizes one `read`-access binding inside `uniforms.textures` for each
          input you declare. The binding name is the resource id of the input.
        - Read with `uniforms.textures.<input_id>.read(gid)` — returns a `float4`.
          (NOT `channels.iChannel0` — that API is gone.)
        - Procedural patterns (gradient, plasma, noise, fractals) do NOT need inputs.
        - Feedback effects (Game of Life, trails) DO need an input that points at the
          same resource as the pass's output, with the resource declared `pingPong = true`.

        Conventions:
        - Use `image` as the final output resource id.
        - `outputResourceID` must match one of your resources (almost always `image`).
        - For a single-pass effect, declare ONE resource named `image` and ONE pass
          named `image` that writes to it.

        ===== EXAMPLE 1: solid red shader =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            uint2 gid [[thread_position_in_grid]];

            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                uniforms.textures.image.write(float4(1.0, 0.0, 0.0, 1.0), gid);
            }
            ```

        ===== EXAMPLE 2: animated gradient (uses uniforms.time) =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            uint2 gid [[thread_position_in_grid]];

            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                float2 uv = float2(gid) / uniforms.resolution;
                float r = 0.5 + 0.5 * sin(uniforms.time + uv.x * 6.28);
                float g = 0.5 + 0.5 * sin(uniforms.time + uv.y * 6.28);
                uniforms.textures.image.write(float4(r, g, 0.2, 1.0), gid);
            }
            ```

        ===== EXAMPLE 3: feedback (ping-pong with self-sample) =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: true }]
        - passes:    [{ id: "image", output: "image", inputs: [{ name: "iChannel0", resource: "image" }] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            uint2 gid [[thread_position_in_grid]];

            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                float4 prev = uniforms.textures.image.read(gid);
                uniforms.textures.image.write(prev * 0.95, gid);
            }
            ```
          (Note: even though `inputs` carries iChannel0-style names, in the MSL you
          access by RESOURCE ID through `uniforms.textures.<resource_id>`.)

        MSL IS STRICTER THAN GLSL:
        - No implicit vector-dimension conversions. `noise3D(vec.xz)` does NOT work —
          `vec.xz` is a `float2` and `noise3D` takes a `float3`. Explicitly construct:
          `noise3D(float3(vec.xz, 0.0))`.
        - Keep raymarching loops bounded with a small max iteration count (≤64).
        - Avoid producing NaN / inf. Clamp final color, guard against divide-by-zero.

        Keep kernels under ~80 lines. Do NOT write `#include` directives.

        DOCUMENT EACH KERNEL:
        Before every `kernel void` declaration, write a short doc comment (one to three
        sentences) describing what the kernel does and which textures it reads / writes.
        Use /// or /** ... */.

        MODIFICATION REQUESTS:
        If the user provides an existing shader, treat it as a modification: keep the
        existing structure and approach, change only what the user asks for. Output the
        complete updated shader (resources, passes, uniforms, full body).
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
    case keychainReadFailed(model: GenerationModel, status: OSStatus)
    case emptyBody(GenerationModel)
    case malformedResponse(model: GenerationModel, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let model):
            return "Missing API key for \(model.displayName). Set it in Settings → Models."

        case .keychainReadFailed(let model, let status):
            return "Couldn't read the API key for \(model.displayName) from the Keychain (status \(status)). The key is likely still set — try again."

        case .emptyBody(let model):
            return "\(model.displayName) returned a response with no kernel body. Try a different model or rephrase your prompt."

        case .malformedResponse(let model, let underlying):
            return "\(model.displayName) returned an incomplete response — try a different model or rephrase. (Details: \(underlying))"
        }
    }
}
