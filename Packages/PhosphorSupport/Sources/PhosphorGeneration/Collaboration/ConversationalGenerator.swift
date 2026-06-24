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

    /// The system prompt the session was configured with, for diagnostics /
    /// export.
    public let instructions: String

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
        self.instructions = instructions
        self.session = LLMSession(
            provider: provider,
            system: instructions,
            tools: .shaderTools(for: document, device: device)
        )
    }

    /// Creates a generator with an injected compile check, for tests without a
    /// Metal device.
    public init(provider: ModelProvider, document: TextDocument, compileCheck: @escaping CompileShaderTool.CompileCheck, instructions: String = ConversationalGenerator.defaultInstructions) {
        self.instructions = instructions
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

    You are collaborating on a single live `.metal` document. It has a
    `/* phosphor:environment ... */` front-matter comment followed by the kernel
    body. The document is NEVER empty: a fresh one already contains valid
    front-matter plus a starter `kernel void image(...)`. ALWAYS call `read`
    first to see the current contents before changing anything — in most cases
    you only need to `edit` the existing body, not rewrite the file.

    The front-matter is TOML, NOT JSON. Do not hand-write a JSON config into the
    front-matter with `write`/`edit`. To change the structured configuration use
    `writeConfiguration` (it emits correct TOML for you).

    There are two ways to edit the document:

    1. Whole-file tools — your DEFAULT surface, just like editing a normal file:
       - `read`  — read the ENTIRE current source (front-matter + body).
       - `write` — overwrite the entire file (rare; only for a full rewrite).
       - `edit`  — replace an exact, unique span anywhere in the file.
    2. Configuration tools — specialists for JUST the structured front-matter:
       - `readConfiguration`  — read the config (textures, passes, uniforms, output).
       - `writeConfiguration` — replace the config as a structured object (TOML).
       PREFER these whenever you change the configuration; only edit front-matter
       text directly with `edit` for trivial tweaks.

    Plus `compileShader` to compile and read back errors.

    ALWAYS call `read` before your first `edit` so you know the exact current
    text — never guess at `oldText`. Typical flow: `read`, then `edit` the kernel
    body (and `writeConfiguration` if the structure changed), then
    `compileShader` and fix any reported errors. Do not claim success until
    `compileShader` reports it compiles cleanly. Never write `#include`
    directives.
    """
}
