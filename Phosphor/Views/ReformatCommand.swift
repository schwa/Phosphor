import PhosphorModel
import PhosphorCompile
import PhosphorGeneration
import PhosphorRuntime
import SwiftUI

/// Focused-value key carrying the active editor's `text` binding so a
/// top-level `commands { }` block can mutate the doc the user is looking at.
extension FocusedValues {
    @Entry var shaderText: Binding<String>?

    /// The active editor's undoable text mutator, so the Edit-menu reformat
    /// command can register a single undo step instead of assigning the
    /// binding directly.
    @Entry var shaderTextMutator: TextMutator?
}

/// `Edit` menu item that re-encodes the active document's front-matter via
/// ``FrontMatterFormatter`` and writes it back.
struct ReformatFrontMatterButton: View {
    @FocusedBinding(\.shaderText) private var text: String?
    @FocusedValue(\.shaderTextMutator) private var mutator: TextMutator?

    var body: some View {
        Button("Reformat Front Matter") {
            guard let current = text else { return }
            let reformatted = FrontMatterFormatter.reformat(current)
            if let mutator {
                mutator.apply(reformatted, actionName: "Reformat Front Matter")
            } else {
                text = reformatted
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(text == nil)
    }
}
