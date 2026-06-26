import Foundation
import PhosphorCompile
import PhosphorModel

/// System prompt text handed to the language model for shader generation.
///
/// The model emits a configuration through the `writeConfiguration` tool, whose
/// contract is ``ConfigurationDTO`` (flat resources / passes / inputs / output).
/// The host synthesizes the per-binding access list when mapping that DTO to
/// the runtime ``PhosphorConfiguration``.
enum GeneratorInstructions {
    /// The full generation instructions plus the `Phosphor.h` helper interface,
    /// so the model knows exactly which helpers and constants are in scope.
    static let instructions: String = full + "\n\n" + availableHelpersSection

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
