import Foundation
import PhosphorCompile
import PhosphorModel

/// System prompt text handed to the language model for shader generation.
///
/// The model emits a configuration through the `writeConfiguration` tool, whose
/// contract is the runtime ``PhosphorConfiguration`` shape directly (textures,
/// passes with explicit per-binding access, uniforms, output) — the same shape
/// `readConfiguration` returns.
public enum GeneratorInstructions {
    /// The full generation instructions plus the `Phosphor.h` helper interface,
    /// so the model knows exactly which helpers and constants are in scope.
    public static let instructions: String = full + "\n\n" + availableHelpersSection

    /// ``instructions`` plus the conversational tool-loop guidance — the
    /// default system prompt for an agentic ``LLMSession`` that talks to the
    /// shader tools.
    public static let conversationalInstructions: String =
        instructions + "\n\n" + toolLoopGuidance

    /// The `Phosphor.h` helper interface, wrapped with a heading explaining
    /// that these are already in scope and must not be re-defined.
    private static var availableHelpersSection: String {
        """
        AVAILABLE HELPERS (already declared in the prelude — call them, do NOT
        re-define them, and do NOT write `#include`):

        \(PhosphorInterface.source)
        """
    }

    /// Full instructions for cloud / Anthropic models with large context.
    private static let full: String = loadPrompt("instructions-full")

    /// Extra guidance for the conversational tool loop: act immediately,
    /// read before edit, use `writeConfiguration` for TOML front-matter,
    /// close every editing turn with a clean `compileShader`.
    ///
    /// Deliberately terse (#133). This block is re-sent on every turn of a
    /// long-running session, so each instruction appears exactly once and
    /// anything already stated in `instructions-full.md` — the kernel
    /// signature, the `gid` file-scope declaration, the `#include` ban — is
    /// not repeated here.
    private static let toolLoopGuidance = """
    WORKING WITH TOOLS

    You are collaborating on a single live `.metal` document: a
    `/* phosphor:environment ... */` TOML front-matter comment followed by the
    kernel body. It is NEVER empty — a fresh document already has valid
    front-matter and a starter `kernel void image(...)`, so you are almost
    always editing, not authoring from scratch.

    Tools:
    - `read` — the entire current source. `write` — overwrite it all (rare).
      `edit` — replace an exact, unique span.
    - `readConfiguration` / `writeConfiguration` — the structured front-matter.
      PREFER these for any configuration change; the front-matter is TOML, not
      JSON, and `writeConfiguration` emits it correctly. Only hand-edit
      front-matter text for trivial tweaks.
    - `compileShader` — compile and read back errors.

    Two rules, both absolute:

    1. ACT IMMEDIATELY. When the user asks for a shader or a change, do it by
       calling tools in the SAME turn. The request is the approval; never reply
       with only a description of what you intend to do. Keep prose brief — the
       work is the tool calls.
    2. READ BEFORE YOU EDIT. The first tool call of any turn that changes the
       document MUST be `read`. `edit` matches `oldText` against the existing
       text, so a guessed `oldText` fails.

    Typical turn: `read`, then `edit` the kernel body (plus `writeConfiguration`
    if the structure changed), then `compileShader` and fix what it reports. A
    turn that changes the shader ends with `compileShader` reporting success —
    do not claim success before that.
    """

    /// Loads a prompt `.md` resource from `Resources/Prompts`. A missing or
    /// unreadable resource is a build error, so it traps (#98).
    private static func loadPrompt(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts") else {
            fatalError("Missing bundled prompt resource Prompts/\(name).md")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read prompt resource Prompts/\(name).md: \(error)")
        }
    }
}
