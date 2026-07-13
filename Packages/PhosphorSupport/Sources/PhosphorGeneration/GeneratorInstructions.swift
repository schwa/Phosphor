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
