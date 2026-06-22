import Foundation
import FoundationModelBackends
import FoundationModels
import os

/// Production ``LanguageModelPort`` backed by Apple's FoundationModels
/// (`LanguageModelSession`): on-device, Private Cloud Compute, or Anthropic.
///
/// Construct one with ``make(model:)``, which builds the right session and,
/// for Anthropic, reads the API key from the Keychain. The session is retained
/// so successive ``respond(to:)`` calls share conversation history.
public final class FoundationModelAdapter: LanguageModelPort, @unchecked Sendable {
    public let displayName: String
    private let session: LanguageModelSession
    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "generator")

    private init(session: LanguageModelSession, displayName: String) {
        self.session = session
        self.displayName = displayName
    }

    /// Builds an adapter for the chosen backend, reading any required API key
    /// from the Keychain.
    ///
    /// - Throws: ``ShaderGeneratorError/missingAPIKey(_:)`` or
    ///   ``ShaderGeneratorError/keychainReadFailed(model:status:)`` for the
    ///   Anthropic backend when the key is absent or unreadable.
    public static func make(model: GenerationModel) throws -> FoundationModelAdapter {
        let session = try makeSession(model: model)
        return FoundationModelAdapter(session: session, displayName: model.displayName)
    }

    public func respond(to prompt: String) async throws -> GeneratedShader {
        do {
            return try await session.respond(to: prompt, generating: GeneratedShader.self).content
        } catch {
            Self.logger.error("[respond] model=\(self.displayName, privacy: .public) decode failed: \(error, privacy: .public)")
            throw ShaderGeneratorError.malformedResponse(model: displayName, underlying: "\(error)")
        }
    }

    public func respondPlan(to prompt: String) async throws -> PlannedApproach {
        do {
            return try await session.respond(to: prompt, generating: PlannedApproach.self).content
        } catch {
            Self.logger.error("[respondPlan] model=\(self.displayName, privacy: .public) decode failed: \(error, privacy: .public)")
            throw ShaderGeneratorError.malformedResponse(model: displayName, underlying: "\(error)")
        }
    }

    private static func makeSession(model: GenerationModel) throws -> LanguageModelSession {
        switch model {
        case .onDevice:
            return LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: GeneratorInstructions.instructions(for: model)
            )

        case .privateCloudCompute:
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: GeneratorInstructions.instructions(for: model)
            )

        case .anthropic(let anthropicModel):
            let apiKey = try readAnthropicKey(model: model)
            let anthropic = AnthropicLanguageModel(apiKey: apiKey, model: anthropicModel.id)
            return LanguageModelSession(
                model: anthropic,
                instructions: GeneratorInstructions.instructions(for: model)
            )
        }
    }

    private static func readAnthropicKey(model: GenerationModel) throws -> String {
        switch KeychainStore.readResult(account: KeychainAccount.anthropicAPIKey) {
        case .found(let value) where !value.isEmpty:
            return value

        case .found, .notFound:
            throw ShaderGeneratorError.missingAPIKey(model)

        case .failed(let status):
            // Transient keychain failure — the key may well be set. Report it
            // distinctly so the user retries instead of re-entering it.
            throw ShaderGeneratorError.keychainReadFailed(model: model, status: status)
        }
    }
}
