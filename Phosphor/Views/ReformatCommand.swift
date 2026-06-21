import PhosphorSupport
import SwiftUI

/// Focused-value key carrying the active editor's `text` binding so a
/// top-level `commands { }` block can mutate the doc the user is looking at.
extension FocusedValues {
    @Entry var shaderText: Binding<String>?
}

/// `Edit` menu item that re-encodes the active document's front-matter via
/// ``FrontMatterFormatter`` and writes it back.
struct ReformatFrontMatterButton: View {
    @FocusedBinding(\.shaderText) private var text: String?

    var body: some View {
        Button("Reformat Front Matter") {
            guard let current = text else { return }
            text = FrontMatterFormatter.reformat(current)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(text == nil)
    }
}
