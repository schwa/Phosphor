import CollaborationKit
import Foundation
import Metal

/// Drives conversational, agentic shader generation over a persistent
/// ``CollaborationKit/LLMSession``.
///
/// It owns a long-running session: the model retains the full conversation, and
/// edits the live `.metal` source through tools (``EditMetalTool``,
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

    /// Sends a user message, optionally with image attachments, and runs the
    /// agentic tool loop until the model stops. Returns the final assistant
    /// text. Tool failures are fed back to the model, not thrown;
    /// harness/transport errors throw.
    ///
    /// The live document is mutated by the model's tool calls during the turn.
    @discardableResult
    public func send(_ prompt: String, images: [ImageContent] = []) async throws -> String {
        try await session.send(text: prompt, images: images)
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
        GeneratorInstructions.instructions + "\n\n" + toolLoopGuidance
    }()

    private static let toolLoopGuidance = """
    WORKING WITH TOOLS

    ACT IMMEDIATELY. When the user asks for a shader or a change, DO IT by
    calling tools in the SAME turn — do not just describe your plan and wait for
    confirmation. The user has already asked; treat that as approval. Never
    reply with only a description of what you intend to do and stop. A turn that
    changes the shader must end with `compileShader` reporting success. Keep any
    prose brief; the work is the tool calls, not the explanation.

    READ BEFORE YOU EDIT — ALWAYS. Your VERY FIRST tool call in any turn that
    changes the document MUST be `read`. Do not call `edit` (or
    `writeConfiguration` followed by `edit`) until you have `read` the current
    source this turn. `edit` matches `oldText` against the EXISTING text, so
    guessing `oldText` will fail.

    The starter document already declares the thread id at file scope:
    `uint2 gid [[thread_position_in_grid]];`. It is shared by all kernels — do
    NOT re-declare `gid` in your edits or you will get a "redefinition of 'gid'"
    compile error. Edit the kernel body, leaving that line in place.

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
    text — never guess at `oldText`. Typical flow: `read` FIRST, then `edit` the
    kernel body (and `writeConfiguration` if the structure changed), then
    `compileShader` and fix any reported errors. Do not claim success until
    `compileShader` reports it compiles cleanly. Never write `#include`
    directives.
    """
}
