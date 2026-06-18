import SwiftTreeSitter
import SwiftTreeSitterLayer
import SwiftUI
import TreeSitterCPP

/// Source view for Metal kernel text. Supports both read-only display and
/// live editing (when given a binding); both modes are syntax-highlighted
/// via tree-sitter's C++ grammar.
///
/// Highlighting is applied as `AttributedString` foreground colors; the
/// editable mode uses `TextEditor(text: Binding<AttributedString>)`.
public struct MetalSourceView: View {
    private enum Storage {
        case readOnly(String)
        case editable(Binding<String>)
    }

    private let storage: Storage

    @State private var attributedText: AttributedString = ""

    /// Read-only view of `text`.
    public init(text: String) {
        self.storage = .readOnly(text)
    }

    /// Editable view bound to `text`. Edits flow back through the binding.
    public init(text: Binding<String>) {
        self.storage = .editable(text)
    }

    public var body: some View {
        content
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .task(id: currentSource) {
                attributedText = AttributedString(currentSource)
                if let highlighted = try? Self.format(currentSource) {
                    attributedText = highlighted
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
        }
    }

    /// Adapts an `AttributedString` binding (what `TextEditor` shows) to/from
    /// the underlying `String` binding (what the document holds). Each edit
    /// writes back the plain characters and triggers a re-highlight.
    private func attributedEditingBinding(plainTextBinding: Binding<String>) -> Binding<AttributedString> {
        Binding(
            get: { attributedText },
            set: { newAttributed in
                let newPlain = String(newAttributed.characters)
                if newPlain != plainTextBinding.wrappedValue {
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

    /// Binding adapter: `TextEditor` reads the live text and writes back
    /// through the underlying binding.
    private var editableBinding: Binding<String> {
        switch storage {
        case .editable(let binding): return binding
        case .readOnly(let text):
            return Binding(
                get: { text },
                set: { _ in }
            )
        }
    }

    /// Builds a syntax-highlighted AttributedString by walking the tree-sitter
    /// parse tree and coloring node ranges.
    static func format(_ source: String) throws -> AttributedString {
        var attributed = AttributedString(source)
        let config = try LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        let parser = Parser()
        try parser.setLanguage(config.language)
        guard let tree = parser.parse(source), let rootNode = tree.rootNode else {
            return attributed
        }
        walk(node: rootNode, attributed: &attributed)
        return attributed
    }

    private static func walk(node: Node, attributed: inout AttributedString) {
        let nsRange = node.range
        if let characterRange = Range(nsRange, in: attributed) {
            switch node.nodeType {
            case "comment":
                attributed[characterRange].foregroundColor = .green
            case "identifier":
                attributed[characterRange].foregroundColor = .blue
            case "number_literal":
                attributed[characterRange].foregroundColor = .orange
            case "primitive_type", "type_identifier", "template_type":
                attributed[characterRange].foregroundColor = .purple
            case "return", "if":
                attributed[characterRange].foregroundColor = .pink
            case "call_expression":
                attributed[characterRange].foregroundColor = .teal
            default:
                break
            }
        }
        node.enumerateChildren { child in
            walk(node: child, attributed: &attributed)
        }
    }
}

private extension Range where Bound == AttributedString.Index {
    init?(_ range: NSRange, in string: AttributedString) {
        let base = String(string.characters)
        guard
            let fromUTF16 = base.utf16.index(base.utf16.startIndex, offsetBy: range.location, limitedBy: base.utf16.endIndex),
            let toUTF16 = base.utf16.index(fromUTF16, offsetBy: range.length, limitedBy: base.utf16.endIndex),
            let from = AttributedString.Index(fromUTF16, within: string),
            let to = AttributedString.Index(toUTF16, within: string)
        else {
            return nil
        }
        self = from..<to
    }
}
