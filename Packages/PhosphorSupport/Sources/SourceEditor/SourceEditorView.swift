import SwiftUI

/// Syntax-highlighted source view. Read-only when given a `String`, editable
/// when given a `Binding<String>`; both modes highlight via tree-sitter.
///
/// Highlighting is applied as `AttributedString` attributes; the editable mode
/// uses `TextEditor(text: Binding<AttributedString>)`.
public struct SourceEditorView: View {
    private enum Storage {
        case readOnly(String)
        case editable(Binding<String>)
    }

    private let storage: Storage
    private let language: SourceLanguage
    private let palette: SyntaxPalette

    @State private var attributedText: AttributedString = ""
    /// Last plain text this view pushed *out* through the binding (i.e. the
    /// user's own typing). Used to tell a typing echo apart from a
    /// programmatic mutation — see ``pushAttributed(_:suppressingUndo:)``.
    @State private var lastUserEdit: String?
    @Environment(\.undoManager) private var undoManager

    /// Read-only view of `text`.
    public init(text: String, language: SourceLanguage, palette: SyntaxPalette = .default) {
        self.storage = .readOnly(text)
        self.language = language
        self.palette = palette
    }

    /// Editable view bound to `text`. Edits flow back through the binding.
    public init(text: Binding<String>, language: SourceLanguage, palette: SyntaxPalette = .default) {
        self.storage = .editable(text)
        self.language = language
        self.palette = palette
    }

    public var body: some View {
        content
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .task(id: HighlightKey(source: currentSource, language: language.id, palette: palette)) {
                let source = currentSource
                // A programmatic mutation arrives here without having gone
                // through the editing binding, so it isn't a keystroke echo.
                let isProgrammatic = source != lastUserEdit
                await pushAttributed(AttributedString(source), suppressingUndo: isProgrammatic)
                if let highlighted = try? SyntaxHighlighter.highlight(source, language: language, palette: palette) {
                    await pushAttributed(highlighted, suppressingUndo: isProgrammatic)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch storage {
        case .readOnly:
            ScrollView {
                Text(attributedText)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 4)
            }

        case .editable(let binding):
            TextEditor(text: attributedEditingBinding(plainTextBinding: binding))
                .scrollContentBackground(.hidden)
        }
    }

    /// Hands a new `AttributedString` to the `TextEditor`.
    ///
    /// `TextEditor` treats an externally-supplied value as an edit and
    /// registers its own undo action for it. That registration opens a fresh
    /// top-level undo group, which purges the redo stack — so redoing a
    /// programmatic mutation was impossible (#79). Suppressing registration
    /// across the update keeps the redo step the document registered alive.
    ///
    /// The text view picks the value up on the next main-actor turn, hence the
    /// hop before re-enabling.
    private func pushAttributed(_ newValue: AttributedString, suppressingUndo: Bool) async {
        guard suppressingUndo, let undoManager else {
            attributedText = newValue
            return
        }
        undoManager.disableUndoRegistration()
        attributedText = newValue
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        undoManager.enableUndoRegistration()
    }

    /// Adapts an `AttributedString` binding (what `TextEditor` shows) to/from
    /// the underlying `String` binding (what the caller holds). Each edit
    /// writes back the plain characters and triggers a re-highlight.
    private func attributedEditingBinding(plainTextBinding: Binding<String>) -> Binding<AttributedString> {
        Binding(
            get: { attributedText },
            set: { newAttributed in
                let newPlain = String(newAttributed.characters)
                if newPlain != plainTextBinding.wrappedValue {
                    lastUserEdit = newPlain
                    plainTextBinding.wrappedValue = newPlain
                }
            }
        )
    }

    /// Active source string for the highlighter to observe.
    private var currentSource: String {
        switch storage {
        case .readOnly(let text): return text
        case .editable(let binding): return binding.wrappedValue
        }
    }
}

/// Composite key for the `.task(id:)` re-highlight. Includes the language and
/// palette so swapping either actually retriggers the highlight pass.
private struct HighlightKey: Hashable {
    var source: String
    var language: String
    var palette: SyntaxPalette
}
