import Foundation
import Metal
import os
import PhosphorCompile
import PhosphorModel

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
    /// When `plan` is true, a planning turn (#74) runs first: the model returns
    /// a ``PlannedApproach`` (intent + shape + prose), which is reported via
    /// `progress(.planned:)`, kept on the result, and folded into the codegen
    /// prompt. The plan and the codegen turn share one session so the model
    /// remembers what it planned.
    @preconcurrency
    public func generate(
        prompt: String,
        existingSource: String = "",
        plan: Bool = false,
        progress: (@Sendable @MainActor (GenerationPhase) -> Void)? = nil
    ) async throws -> GenerationResult {
        let priorPrompts = PromptHistory.extract(from: existingSource)
        let allPrompts = priorPrompts + [prompt]

        // Records every model turn (request + decoded response / error) so the
        // full wire log can be persisted (#99). On any failure we rethrow a
        // GenerationFailure carrying whatever exchanges were captured, so the
        // failed requests/responses aren't lost.
        let recorder = ExchangeRecorder()
        do {
            return try await runGenerate(
                prompt: prompt, existingSource: existingSource, allPrompts: allPrompts,
                plan: plan, recorder: recorder, progress: progress
            )
        } catch {
            throw GenerationFailure(underlying: error, exchanges: recorder.exchanges)
        }
    }

    @preconcurrency
    private func runGenerate(
        prompt: String,
        existingSource: String,
        allPrompts: [String],
        plan: Bool,
        recorder: ExchangeRecorder,
        progress: (@Sendable @MainActor (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult {
        // Optional planning turn.
        var generatedPlan: GeneratedPlan?
        if plan {
            await progress?(.planning)
            let approach = try await respondPlan(prompt: prompt, existingSource: existingSource, recorder: recorder)
            let built = GeneratedPlan(approach: approach, originalPrompt: prompt, sourceCode: existingSource)
            generatedPlan = built
            await progress?(.planned(built))
        }

        // First attempt.
        await progress?(.generating)
        let initialPrompt = generatedPlan.map(Self.buildCodegenPrompt(plan:))
            ?? Self.buildPrompt(userPrompt: prompt, existingSource: existingSource)

        // A single corrective retry is allowed, shared across decode and
        // compile failures (#94): whichever failure happens first on the first
        // attempt consumes the one retry. We never stack two retries.
        var corrections: [GenerationCorrection] = []

        do {
            let generated = try await respond(to: initialPrompt, label: "initial", kind: .codegen, recorder: recorder)
            return try await finish(
                generated: generated, prompts: allPrompts, plan: generatedPlan,
                corrections: &corrections, recorder: recorder, progress: progress
            )
        } catch let error as ShaderGeneratorError {
            // Only schema-decode failures are recoverable here; rethrow the rest
            // (missing key, empty body, …).
            guard case .malformedResponse(_, let underlying) = error else { throw error }
            corrections.append(GenerationCorrection(attempt: 1, kind: .decode, message: underlying))
            Self.logger.error("""
                [decode-retry] model=\(model.displayName, privacy: .public) \
                first attempt didn't match the schema; retrying. error=\"\(underlying, privacy: .public)\"
                """)
            await progress?(.retryingMalformed(decodeError: underlying))
            let followUp = Self.buildMalformedRetryPrompt(decodeError: underlying)
            let generated = try await respond(to: followUp, label: "decode-retry", kind: .malformedRetry, recorder: recorder)
            // The retry already consumed our one retry, so a compile failure
            // here is returned as-is (no second compile retry).
            let source = try generated.toMetalSource(prompts: allPrompts)
            recorder.setLastProducedSource(source)
            return GenerationResult(source: source, title: generated.title, corrections: corrections, plan: generatedPlan, exchanges: recorder.exchanges)
        }
    }

    /// Renders + compile-checks a decoded response. If it fails to compile and
    /// we still have our retry budget (`corrections` empty), runs the one
    /// compile retry. Otherwise returns the result as-is.
    private func finish(
        generated firstGenerated: GeneratedShader,
        prompts: [String],
        plan: GeneratedPlan?,
        corrections: inout [GenerationCorrection],
        recorder: ExchangeRecorder,
        progress: (@Sendable @MainActor (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult {
        var generated = firstGenerated
        var source = try generated.toMetalSource(prompts: prompts)
        recorder.setLastProducedSource(source)

        // No device / no front-matter to validate -> return as-is.
        guard let device else { return GenerationResult(source: source, title: generated.title, corrections: corrections, plan: plan, exchanges: recorder.exchanges) }

        if let compileError = Self.tryCompile(source: source, device: device), corrections.isEmpty {
            // Keep the failure around even though we're about to fix it (#96).
            corrections.append(GenerationCorrection(attempt: 1, kind: .compile, message: compileError))
            Self.logger.error("""
                [compile-retry] model=\(model.displayName, privacy: .public) \
                first attempt failed to compile; retrying. error=\"\(compileError, privacy: .public)\"
                """)
            await progress?(.retrying(compileError: compileError))
            let followUp = Self.buildRetryPrompt(compileError: compileError)
            generated = try await respond(to: followUp, label: "retry", kind: .compileRetry, recorder: recorder)
            source = try generated.toMetalSource(prompts: prompts)
            recorder.setLastProducedSource(source)
        }
        return GenerationResult(source: source, title: generated.title, corrections: corrections, plan: plan, exchanges: recorder.exchanges)
    }

    /// Sends the planning prompt and returns the model's approach, recording
    /// the exchange.
    private func respondPlan(prompt: String, existingSource: String, recorder: ExchangeRecorder) async throws -> PlannedApproach {
        let planPrompt = Self.buildPlanPrompt(userPrompt: prompt, existingSource: existingSource)
        let started = Date()
        let clock = ContinuousClock.now
        do {
            let approach = try await model.respondPlan(to: planPrompt)
            recorder.record(GenerationExchange(
                kind: .plan, model: model.displayName, instructions: model.instructions,
                request: planPrompt, response: .init(approach: approach),
                startedAt: started, elapsed: clock.elapsedSeconds))
            return approach
        } catch {
            recorder.record(GenerationExchange(
                kind: .plan, model: model.displayName, instructions: model.instructions,
                request: planPrompt, error: "\(error)",
                startedAt: started, elapsed: clock.elapsedSeconds))
            throw error
        }
    }

    /// Sends a prompt through the port, records the exchange, logs the result,
    /// and rejects an empty body.
    private func respond(to prompt: String, label: String, kind: GenerationExchange.Kind, recorder: ExchangeRecorder) async throws -> GeneratedShader {
        let started = Date()
        let clock = ContinuousClock.now
        let generated: GeneratedShader
        do {
            generated = try await model.respond(to: prompt)
        } catch {
            recorder.record(GenerationExchange(
                kind: kind, model: model.displayName, instructions: model.instructions,
                request: prompt, error: "\(error)",
                startedAt: started, elapsed: clock.elapsedSeconds))
            throw error
        }
        recorder.record(GenerationExchange(
            kind: kind, model: model.displayName, instructions: model.instructions,
            request: prompt, response: .init(shader: generated),
            startedAt: started, elapsed: clock.elapsedSeconds))
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

    /// Feedback prompt for a schema-decode failure: tell the model its last
    /// response didn't match the required structure and ask for a complete,
    /// well-formed one. The session retains history, so it knows what it tried.
    static func buildMalformedRetryPrompt(decodeError: String) -> String {
        """
            Your previous response could not be decoded into the required shader structure:

            \(decodeError)

            Return a COMPLETE, well-formed response with every required field populated:
            title, body (the full MSL source), resources, passes, uniforms, outputResourceID,
            and flipY. Do not leave any field undefined or use placeholder values. Keep the same
            intent as the user's request.
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

    /// The prompt for the planning turn (#74). Prepends the planning
    /// instructions, then the user's request and any pasted source verbatim.
    static func buildPlanPrompt(userPrompt: String, existingSource: String) -> String {
        let trimmedSource = existingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = GeneratorInstructions.planning + "\n\n"
        if trimmedSource.isEmpty {
            out += "User request: \(userPrompt)"
        } else {
            out += """
                The user has existing shader source (either a Phosphor shader to modify, or pasted
                code to port). Plan accordingly.

                ===== SOURCE =====
                \(trimmedSource)
                ===== END =====

                User request: \(userPrompt)
                """
        }
        return out
    }

    /// The codegen prompt when a plan exists (#74): hand the model the plan it
    /// just produced (it's also in session history) plus the verbatim request
    /// and source, and ask for the shader.
    static func buildCodegenPrompt(plan: GeneratedPlan) -> String {
        let trimmedSource = plan.sourceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = """
            Now write the shader, following the plan you just made.

            PLAN
            Intent: \(plan.intent)
            Shape: \(plan.shape.rawValue)
            \(plan.plan)

            """
        if !trimmedSource.isEmpty {
            out += """

                ===== SOURCE TO PORT =====
                \(trimmedSource)
                ===== END =====

                """
        }
        out += "\nUser request: \(plan.originalPrompt)"
        return out
    }
}

/// A recoverable failure that occurred during generation and was corrected by
/// a follow-up turn. Kept on ``GenerationResult`` so the error survives the
/// auto-correction instead of being discarded once the retry succeeds (#96).
///
/// Modeled generically over an error ``Kind`` so future retry classes (e.g.
/// malformed/decode failures, #94) reuse the same shape.
public struct GenerationCorrection: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The produced shader failed to compile; the Metal compiler errors
        /// were fed back to the model.
        case compile
        /// The response didn't decode into the schema; the decode error was
        /// fed back to the model.
        case decode
    }

    /// Which attempt produced this failure (1 = the first attempt).
    public let attempt: Int
    public let kind: Kind
    /// The error text that was fed back to the model.
    public let message: String

    public init(attempt: Int, kind: Kind, message: String) {
        self.attempt = attempt
        self.kind = kind
        self.message = message
    }
}

/// The outcome of a successful generation: the full `.metal` source, the
/// model-provided title, and any errors that were auto-corrected along the way.
public struct GenerationResult: Hashable, Sendable {
    public let source: String
    public let title: String
    /// Failures that were corrected by a retry, oldest first. Empty on a
    /// first-try success. Surfaced in the chat so the user can see what went
    /// wrong and that it was fixed (#96).
    public let corrections: [GenerationCorrection]
    /// The plan that drove this generation, when planning mode was on (#74).
    /// `nil` for a direct (unplanned) generation.
    public let plan: GeneratedPlan?
    /// Every model turn (request + decoded response / error), oldest first
    /// (#99). The complete wire record of this generation.
    public let exchanges: [GenerationExchange]

    public init(
        source: String, title: String,
        corrections: [GenerationCorrection] = [], plan: GeneratedPlan? = nil,
        exchanges: [GenerationExchange] = []
    ) {
        self.source = source
        self.title = title
        self.corrections = corrections
        self.plan = plan
        self.exchanges = exchanges
    }
}

/// Thrown by ``ShaderGenerator/generate(prompt:existingSource:plan:progress:)``
/// when generation ultimately fails, carrying the model exchanges captured up
/// to the failure so the full wire log survives the error (#99). Unwrap
/// ``underlying`` for the user-facing message.
public struct GenerationFailure: Error {
    public let underlying: any Error
    public let exchanges: [GenerationExchange]

    public init(underlying: any Error, exchanges: [GenerationExchange]) {
        self.underlying = underlying
        self.exchanges = exchanges
    }

    public var localizedDescription: String { "\(underlying)" }
}

/// Accumulates ``GenerationExchange`` records across the turns of one
/// generation. A reference type so the value-type ``ShaderGenerator`` can
/// thread it through its async helpers.
final class ExchangeRecorder: @unchecked Sendable {
    private(set) var exchanges: [GenerationExchange] = []
    func record(_ exchange: GenerationExchange) { exchanges.append(exchange) }

    /// Attaches the assembled `.metal` source to the most recent exchange
    /// (the codegen turn that produced it).
    func setLastProducedSource(_ source: String) {
        guard !exchanges.isEmpty else { return }
        exchanges[exchanges.count - 1].producedSource = source
    }
}

extension ContinuousClock.Instant {
    /// Seconds elapsed from this instant to now.
    var elapsedSeconds: Double {
        let d = duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Reported by ``ShaderGenerator/generate(prompt:existingSource:progress:)``
/// so the UI can show what's happening during long generations.
public enum GenerationPhase: Hashable, Sendable {
    /// The model is producing its initial response.
    case generating
    /// The first response failed to compile; the model is being asked to fix it.
    case retrying(compileError: String)
    /// The first response didn't match the schema; the model is being asked to
    /// return a complete, well-formed response.
    case retryingMalformed(decodeError: String)
    /// Planning mode (#74): the model is producing the plan turn.
    case planning
    /// Planning mode: the plan is ready (shown in the transcript) and codegen
    /// is about to begin.
    case planned(GeneratedPlan)
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
