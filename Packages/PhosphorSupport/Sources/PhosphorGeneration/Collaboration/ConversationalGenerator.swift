import CollaborationKit
import Foundation
import Metal

/// Drives conversational, agentic shader generation over a persistent
/// ``CollaborationKit/LLMSession``.
///
/// Unlike the one-shot ``ShaderGenerator`` (which runs a single host-driven
/// generate→compile→retry turn against a ``LanguageModelPort``), this owns a
/// long-running session: the model retains the full conversation, and edits the
/// live `.metal` source through tools (``EditMetalTool``,
/// ``ReadConfigurationTool``, ``WriteConfigurationTool``, ``CompileShaderTool``).
/// The model converges by editing and compiling, not by re-emitting the file.
///
/// Observe ``events`` to stream assistant prose, tool calls, and usage into a
/// UI; the live document updates as the model edits.
public final class ConversationalGenerator: Sendable {
    private let session: LLMSession

    /// A stream of session events: streamed assistant text, tool calls, tool
    /// results, token usage, and turn completion.
    public var events: AsyncStream<SessionEvent> { session.events }

    /// Creates a generator wired to a provider and the shader tool set over a
    /// shared document.
    ///
    /// - Parameters:
    ///   - provider: The CollaborationKit backend (Anthropic, OpenAI-compatible).
    ///   - document: The live `.metal` source the tools read and write.
    ///   - device: Metal device used by the `compileShader` tool.
    ///   - instructions: System prompt (defaults to the full generator
    ///     instructions plus the helper interface).
    public init(provider: ModelProvider, document: TextDocument, device: MTLDevice, instructions: String = ConversationalGenerator.defaultInstructions) {
        self.session = LLMSession(
            provider: provider,
            system: instructions,
            tools: .shaderTools(for: document, device: device)
        )
    }

    /// Creates a generator with an injected compile check, for tests without a
    /// Metal device.
    public init(provider: ModelProvider, document: TextDocument, compileCheck: @escaping CompileShaderTool.CompileCheck, instructions: String = ConversationalGenerator.defaultInstructions) {
        self.session = LLMSession(
            provider: provider,
            system: instructions,
            tools: .shaderTools(for: document, compileCheck: compileCheck)
        )
    }

    /// Sends a user message and runs the agentic tool loop until the model
    /// stops. Returns the final assistant text. Tool failures are fed back to
    /// the model, not thrown; harness/transport errors throw.
    ///
    /// The live document is mutated by the model's tool calls during the turn.
    @discardableResult
    public func send(_ prompt: String) async throws -> String {
        try await session.send(prompt)
    }

    /// The conversation so far, for persistence in a bundle document.
    public var messages: [Message] {
        get async { await session.messages }
    }

    /// Cumulative token usage across the session.
    public var totalUsage: TokenUsage {
        get async { await session.totalUsage }
    }

    /// The default system prompt: the full generator instructions plus the
    /// `Phosphor.h` helper interface, with the conversational tool loop
    /// explained.
    public static let defaultInstructions: String = {
        let base = GeneratorInstructions.instructions(for: .privateCloudCompute)
        return base + "\n\n" + toolLoopGuidance
    }()

    private static let toolLoopGuidance = """
    WORKING WITH TOOLS

    You are collaborating on a single live `.metal` document. Use the tools:
    - `readConfiguration` to inspect the structured front-matter (textures, \
    passes, uniforms, output).
    - `writeConfiguration` to replace that configuration when the structure \
    changes (rare — usually it stays the same).
    - `editMetal` to make exact, unique edits to the kernel body.
    - `compileShader` to compile and read back any errors.

    Loop: edit the body and/or configuration, then call `compileShader` and fix \
    any reported errors before you finish. Do not claim success until \
    `compileShader` reports it compiles cleanly. Output ONLY MSL in the body; \
    never include TOML front-matter or `#include` directives in an `editMetal`.
    """
}
