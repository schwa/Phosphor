import SwiftUI

/// Doc-agnostic handle for performing a single, undoable full-text mutation.
///
/// The two `DocumentGroup` document types (`PhosphorMetalDocument` and
/// `PhosphorBundleDocument`) each expose a `setText(...)` method that registers
/// an undo step. The shared editor UI (`ShaderEditorView` and the programmatic
/// mutation sites it hosts) is doc-agnostic and works against a plain
/// `Binding<String>`, so it can't call those methods directly. This struct
/// bridges the gap: each doc view constructs one — capturing its
/// `@Environment(\.undoManager)` and routing to the document's `setText` — and
/// passes it down.
///
/// Call `apply(_:actionName:)` for any programmatic mutation (Reformat,
/// Generate, Configuration edit) so it lands as one coalesced, named undo step.
struct TextMutator {
    /// (newText, actionName) -> performs the undoable replacement.
    private let perform: (String, String) -> Void

    init(_ perform: @escaping (String, String) -> Void) {
        self.perform = perform
    }

    func apply(_ newText: String, actionName: String) {
        perform(newText, actionName)
    }
}

extension EnvironmentValues {
    /// The active document's undoable text mutator, injected by the per-doc
    /// top-level view. `nil` in previews / contexts without a document.
    @Entry var textMutator: TextMutator?
}
