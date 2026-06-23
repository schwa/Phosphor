import Foundation

/// The single dependency ``ShaderGenerator`` has on a language-model backend.
///
/// One port call == one model turn. The generator owns the prompt/retry logic
/// and the compile check; the port owns only "send this prompt, decode a
/// ``GeneratedShader`` from the reply." Conforming types keep a session across
/// calls so the model retains conversation history (needed for the retry turn).
///
/// Production conformance is ``FoundationModelAdapter`` (Apple Intelligence /
/// Anthropic via FoundationModels). Tests use a fake that returns scripted
/// replies, so the full generate flow runs with no network or device.
public protocol LanguageModelPort: Sendable {
    /// Human-readable backend name, used in error messages.
    var displayName: String { get }

    /// The system instructions the session was configured with, recorded in
    /// the generation log (#99).
    var instructions: String { get }

    /// Sends `prompt` and decodes a ``GeneratedShader`` from the reply.
    ///
    /// - Throws: ``ShaderGeneratorError/malformedResponse(model:underlying:)``
    ///   if the reply can't be decoded into the schema.
    func respond(to prompt: String) async throws -> GeneratedShader

    /// Sends `prompt` and decodes a ``PlannedApproach`` from the reply. Used
    /// for the optional planning turn (#74); shares the same session, so the
    /// plan stays in conversation history for the codegen turn that follows.
    ///
    /// - Throws: ``ShaderGeneratorError/malformedResponse(model:underlying:)``
    ///   if the reply can't be decoded into the schema.
    func respondPlan(to prompt: String) async throws -> PlannedApproach
}
