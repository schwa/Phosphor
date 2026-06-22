#if DEBUG
import SwiftUI

/// Debug-only menu commands for exercising app internals. Compiled out of
/// release builds.
struct DebugCommands: Commands {
    var body: some Commands {
        CommandMenu("Debug") {
            AppendCommentButton()
        }
    }
}

/// Appends a throwaway comment line to the active document via the same
/// undoable ``TextMutator`` path used by Generate / Reformat. Lets us test
/// undo/redo without the async Generate machinery.
private struct AppendCommentButton: View {
    @FocusedBinding(\.shaderText) private var text: String?
    @FocusedValue(\.shaderTextMutator) private var mutator: TextMutator?

    var body: some View {
        Button("Append Comment") {
            guard let current = text else { return }
            let updated = current + "\n// debug comment\n"
            if let mutator {
                mutator.apply(updated, actionName: "Append Comment")
            } else {
                text = updated
            }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(text == nil)
    }
}
#endif
