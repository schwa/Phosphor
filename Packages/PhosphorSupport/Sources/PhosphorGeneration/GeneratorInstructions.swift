import Foundation
import PhosphorCompile
import PhosphorModel

/// System prompts handed to the language model for shader generation.
///
/// Schema note: the `@Generable` schema (resources / passes / inputs /
/// outputResourceID) is the *Foundation-Models-visible* contract. The runtime
/// model is different (textures + per-binding access). The host adapter inside
/// ``GeneratedShader/toPhosphorConfiguration()`` synthesizes the binding list
/// automatically: each pass gets a `write` binding for its declared `output`
/// plus a `read` binding for each declared input.
enum GeneratorInstructions {
    /// Selects the instruction set sized for the model's context window.
    ///
    /// Large-context models also get the full ``PhosphorInterface`` (the
    /// declarations-only view of `Phosphor.h`) appended so the model knows
    /// exactly which helpers and constants are in scope. The on-device model's
    /// context is too small for the full list; its compact prompt names the
    /// key helpers in prose instead.
    static func instructions(for model: GenerationModel) -> String {
        switch model {
        case .onDevice:
            return onDevice

        case .privateCloudCompute, .anthropic:
            return full + "\n\n" + availableHelpersSection
        }
    }

    /// Instructions for the optional *planning* turn (#74). The model returns
    /// a ``PlannedApproach`` (intent + shape + prose), NOT code. Kept short;
    /// the heavy MSL rules are saved for the codegen turn that follows.
    static let planning: String = loadPrompt("planning")

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
    static let full: String = loadPrompt("instructions-full")

    /// Compact instructions for the on-device model, whose context window is
    /// small (~4096 tokens). Covers just the essentials; the full ``full``
    /// set blows past the limit.
    static let onDevice: String = loadPrompt("instructions-ondevice")

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
