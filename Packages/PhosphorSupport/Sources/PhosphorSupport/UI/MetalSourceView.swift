import SwiftTreeSitter
import SwiftTreeSitterLayer
import SwiftUI
import TreeSitterCPP
import TreeSitterTOML

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
                .scrollContentBackground(.hidden)
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

    /// Builds a syntax-highlighted AttributedString by walking the tree-sitter
    /// parse tree and coloring node ranges. C++ pass first, then a TOML
    /// re-color over the front-matter block (if present).
    static func format(_ source: String) throws -> AttributedString {
        var attributed = AttributedString(source)

        let cppConfig = try LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        let cppParser = Parser()
        try cppParser.setLanguage(cppConfig.language)
        if let tree = cppParser.parse(source), let root = tree.rootNode {
            walk(node: root, attributed: &attributed)
        }

        // Locate the front-matter `/* phosphor:environment ... */` block
        // (matches PhosphorFrontMatter.extractBlock's rules but as offsets
        // in the original source, not the trimmed view). Re-highlight just
        // the TOML body with the TOML grammar.
        if let tomlRange = findFrontMatterTOMLRange(in: source) {
            let tomlText = String(source[tomlRange])
            let tomlConfig = try LanguageConfiguration(tree_sitter_toml(), name: "toml")
            let tomlParser = Parser()
            try tomlParser.setLanguage(tomlConfig.language)
            if let tree = tomlParser.parse(tomlText), let root = tree.rootNode {
                let baseOffset = source.utf16.distance(from: source.startIndex, to: tomlRange.lowerBound)
                walkTOML(node: root, attributed: &attributed, baseUTF16Offset: baseOffset)
            }
        }
        return attributed
    }

    /// Returns the UTF-16 range, in `source`, of the TOML body inside the
    /// `/* phosphor:environment ... */` block (i.e. just after the marker,
    /// up to but not including the closing `*/`). nil if not found.
    private static func findFrontMatterTOMLRange(in source: String) -> Range<String.Index>? {
        let openMarker = "/* phosphor:environment"
        guard let openRange = source.range(of: openMarker) else { return nil }
        let afterMarker = openRange.upperBound
        guard let closeRange = source.range(of: "*/", range: afterMarker..<source.endIndex) else {
            return nil
        }
        return afterMarker..<closeRange.lowerBound
    }

    private static func walkTOML(node: Node, attributed: inout AttributedString, baseUTF16Offset: Int) {
        let nsRange = NSRange(
            location: node.range.location + baseUTF16Offset,
            length: node.range.length
        )
        if let characterRange = Range(nsRange, in: attributed) {
            switch node.nodeType {
            case "comment":
                attributed[characterRange].foregroundColor = .green

            case "bare_key", "dotted_key":
                attributed[characterRange].foregroundColor = .blue

            case "string":
                attributed[characterRange].foregroundColor = .red

            case "integer", "float":
                attributed[characterRange].foregroundColor = .orange

            case "boolean":
                attributed[characterRange].foregroundColor = .pink

            case "table_header", "array_table_header":
                attributed[characterRange].foregroundColor = .purple

            default:
                break
            }
        }
        node.enumerateChildren { child in
            walkTOML(node: child, attributed: &attributed, baseUTF16Offset: baseUTF16Offset)
        }
    }

    private static func walk(node: Node, attributed: inout AttributedString) {
        let nsRange = node.range
        if let characterRange = Range(nsRange, in: attributed) {
            switch node.nodeType {
            case "comment":
                attributed[characterRange].foregroundColor = .green
                attributed[characterRange].font = .system(.body, design: .monospaced).italic()

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

// MARK: - Previews

#Preview("Read-only") {
    MetalSourceView(text: """
    // tiny kernel
    kernel void image(uint2 gid [[thread_position_in_grid]]) {
        float v = 0.5;
        if (gid.x > 100) { v = 1.0; }
    }
    """)
        .frame(width: 480, height: 240)
}

#Preview("Editable") {
    EditablePreviewHost()
        .frame(width: 480, height: 240)
}

/// Hosts a `@State` String so the editable `MetalSourceView` preview can
/// take a real `Binding`.
private struct EditablePreviewHost: View {
    @State private var source: String = "kernel void image() {\n    // edit me\n}\n"
    var body: some View {
        MetalSourceView(text: $source)
    }
}
