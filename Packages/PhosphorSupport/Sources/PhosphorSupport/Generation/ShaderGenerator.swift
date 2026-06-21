import Foundation
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

    public static let opus = Self(id: "claude-opus-4-8", displayName: "Claude Opus")

    public static let all: [Self] = [.opus]
}

/// Turns a natural-language prompt into a Phosphor `.metal` source string.
///
/// The generator owns the *flow* — prompt assembly, the compile-and-retry
/// loop, empty-body checks — and depends only on a ``LanguageModelPort`` for
/// the actual model turns. Construct the port with
/// ``FoundationModelAdapter/make(model:)`` in production, or a fake in tests.
public struct ShaderGenerator {
    private let model: LanguageModelPort
    private let device: MTLDevice?

    /// - Parameters:
    ///   - model: the language-model backend to drive.
    ///   - device: Metal device used for the compile check. Defaults to the
    ///     system default; pass `nil` (or run on a machine without Metal) to
    ///     skip the compile/retry step.
    public init(model: LanguageModelPort, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.model = model
        self.device = device
    }

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
        existingSource: String = "",
        progress: (@Sendable @MainActor (GenerationPhase) -> Void)? = nil
    ) async throws -> String {
        let priorPrompts = PromptHistory.extract(from: existingSource)

        // First attempt.
        await progress?(.generating)
        let initialPrompt = Self.buildPrompt(userPrompt: prompt, existingSource: existingSource)
        var generated = try await respond(to: initialPrompt, label: "initial")
        var source = try generated.toMetalSource(prompts: priorPrompts + [prompt])

        // Compile check. If we don't have a device or the source has no
        // front-matter we can validate, just return as-is.
        guard let device else { return source }
        if let compileError = Self.tryCompile(source: source, device: device) {
            await progress?(.retrying(compileError: compileError))
            // One retry. The port retains history so the model already knows
            // what it just produced.
            let followUp = Self.buildRetryPrompt(compileError: compileError)
            generated = try await respond(to: followUp, label: "retry")
            source = try generated.toMetalSource(prompts: priorPrompts + [prompt])
        }
        return source
    }

    /// Sends a prompt through the port, logs the result, and rejects an empty
    /// body.
    private func respond(to prompt: String, label: String) async throws -> GeneratedShader {
        let generated = try await model.respond(to: prompt)
        Self.logGeneration(label: label, model: model.displayName, generated: generated)
        if generated.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ShaderGeneratorError.emptyBody(model: model.displayName)
        }
        return generated
    }

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "generator")

    /// Logs what the model produced so we can debug why something looked wrong
    /// without losing the response.
    private static func logGeneration(label: String, model: String, generated: GeneratedShader) {
        let bodyChars = generated.body.count
        let bodyHasKernel = generated.body.contains("kernel void")
        logger.info("""
            [\(label, privacy: .public)] model=\(model, privacy: .public) \
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

    /// Parses `source` for front-matter and tries to compile each declared
    /// pass. Returns a human-readable error string on the first failure, or
    /// nil if everything compiles (or if the source has no front-matter we
    /// can drive a compile from).
    private static func tryCompile(source: String, device: MTLDevice) -> String? {
        let parsed = ParsedPhosphorSource(source: source)
        guard parsed.hasFrontMatter else { return nil }
        let compiled = ShaderCompiler.compile(parsed: parsed, device: device)
        return compiled.firstCompileError
    }

    static func buildRetryPrompt(compileError: String) -> String {
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
    static func buildPrompt(userPrompt: String, existingSource: String) -> String {
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
}

/// Reported by ``ShaderGenerator/generate(prompt:existingSource:progress:)``
/// so the UI can show what's happening during long generations.
public enum GenerationPhase: Hashable, Sendable {
    /// The model is producing its initial response.
    case generating
    /// The first response failed to compile; the model is being asked to fix it.
    case retrying(compileError: String)
}

/// Errors that ``ShaderGenerator`` and its adapters may raise.
public enum ShaderGeneratorError: Error, LocalizedError {
    case missingAPIKey(GenerationModel)
    case keychainReadFailed(model: GenerationModel, status: OSStatus)
    case emptyBody(model: String)
    case malformedResponse(model: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let model):
            return "Missing API key for \(model.displayName). Set it in Settings → Models."

        case .keychainReadFailed(let model, let status):
            return "Couldn't read the API key for \(model.displayName) from the Keychain (status \(status)). The key is likely still set — try again."

        case .emptyBody(let model):
            return "\(model) returned a response with no kernel body. Try a different model or rephrase your prompt."

        case .malformedResponse(let model, let underlying):
            return "\(model) returned an incomplete response — try a different model or rephrase. (Details: \(underlying))"
        }
    }
}
