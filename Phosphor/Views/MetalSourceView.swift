import PhosphorSupport
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
struct MetalSourceView: View {
    private enum Storage {
        case readOnly(String)
        case editable(Binding<String>)
    }

    private let storage: Storage
    private let palette: SyntaxPalette

    @State private var attributedText: AttributedString = ""

    /// Read-only view of `text`.
    init(text: String, palette: SyntaxPalette = .default) {
        self.storage = .readOnly(text)
        self.palette = palette
    }

    /// Editable view bound to `text`. Edits flow back through the binding.
    init(text: Binding<String>, palette: SyntaxPalette = .default) {
        self.storage = .editable(text)
        self.palette = palette
    }

    var body: some View {
        content
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .task(id: HighlightKey(source: currentSource, palette: palette)) {
                attributedText = AttributedString(currentSource)
                if let highlighted = try? Self.format(currentSource, palette: palette) {
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
    /// re-color over the front-matter block (if present). A per-line
    /// backdrop pass runs first so non-token whitespace also gets the
    /// backdrop.
    static func format(_ source: String, palette: SyntaxPalette) throws -> AttributedString {
        var attributed = AttributedString(source)

        // Default foreground for everything not specifically recognized
        // by the walker (punctuation, operators, whitespace, etc.).
        let fullRange = attributed.startIndex..<attributed.endIndex
        attributed[fullRange].foregroundColor = palette.foreground

        // Per-line backdrop pass. Done before the colored tokens so the
        // backdrop applies to every character on every line, including
        // whitespace and unrecognized tokens.
        if let backdrop = palette.tokenBackground {
            applyLineBackdrop(to: &attributed, source: source, color: backdrop)
        }

        let cppConfig = try LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        let cppParser = Parser()
        try cppParser.setLanguage(cppConfig.language)
        if let tree = cppParser.parse(source), let root = tree.rootNode {
            walk(node: root, attributed: &attributed, palette: palette)
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
                walkTOML(node: root, attributed: &attributed, baseUTF16Offset: baseOffset, palette: palette)
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

    private static func walkTOML(node: Node, attributed: inout AttributedString, baseUTF16Offset: Int, palette: SyntaxPalette) {
        let nsRange = NSRange(
            location: node.range.location + baseUTF16Offset,
            length: node.range.length
        )
        if let characterRange = Range(nsRange, in: attributed) {
            switch node.nodeType {
            case "comment":
                color(&attributed, range: characterRange, foreground: palette.comment, palette: palette)

            case "bare_key", "dotted_key":
                color(&attributed, range: characterRange, foreground: palette.tomlKey, palette: palette)

            case "string":
                color(&attributed, range: characterRange, foreground: palette.tomlString, palette: palette)

            case "integer", "float":
                color(&attributed, range: characterRange, foreground: palette.tomlNumber, palette: palette)

            case "boolean":
                color(&attributed, range: characterRange, foreground: palette.tomlBoolean, palette: palette)

            case "table_header", "array_table_header":
                color(&attributed, range: characterRange, foreground: palette.tomlTableHeader, palette: palette)

            default:
                break
            }
        }
        node.enumerateChildren { child in
            walkTOML(node: child, attributed: &attributed, baseUTF16Offset: baseUTF16Offset, palette: palette)
        }
    }

    private static func walk(node: Node, attributed: inout AttributedString, palette: SyntaxPalette) {
        let nsRange = node.range
        if let characterRange = Range(nsRange, in: attributed) {
            switch node.nodeType {
            case "comment":
                color(&attributed, range: characterRange, foreground: palette.comment, palette: palette)
                attributed[characterRange].font = .system(.body, design: .monospaced).italic()

            case "identifier":
                color(&attributed, range: characterRange, foreground: palette.identifier, palette: palette)

            case "number_literal":
                color(&attributed, range: characterRange, foreground: palette.number, palette: palette)

            case "primitive_type", "type_identifier", "template_type":
                color(&attributed, range: characterRange, foreground: palette.type, palette: palette)

            case "return", "if":
                color(&attributed, range: characterRange, foreground: palette.keyword, palette: palette)

            case "call_expression":
                color(&attributed, range: characterRange, foreground: palette.callExpression, palette: palette)

            default:
                break
            }
        }
        node.enumerateChildren { child in
            walk(node: child, attributed: &attributed, palette: palette)
        }
    }

    /// Applies a foreground color to the given range. The per-line
    /// backdrop is already laid down by ``applyLineBackdrop`` before any
    /// token coloring runs, so this stays simple.
    private static func color(
        _ attributed: inout AttributedString,
        range: Range<AttributedString.Index>,
        foreground: Color,
        palette: SyntaxPalette
    ) {
        attributed[range].foregroundColor = foreground
    }

    /// For each line in `source` (delimited by `\n`), set `backgroundColor`
    /// on every character in that line. The newline itself is left
    /// uncolored so the backdrop doesn't bleed past the line edge.
    private static func applyLineBackdrop(
        to attributed: inout AttributedString,
        source: String,
        color: Color
    ) {
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let newlineIndex = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
            if cursor < newlineIndex {
                let nsRange = NSRange(cursor..<newlineIndex, in: source)
                if let range = Range(nsRange, in: attributed) {
                    attributed[range].backgroundColor = color
                }
            }
            cursor = newlineIndex < source.endIndex
                ? source.index(after: newlineIndex)
                : source.endIndex
        }
    }
}

/// Composite key for the `.task(id:)` re-highlight. Includes the palette
/// so switching layouts (which swap palettes) actually retriggers the
/// highlight pass.
private struct HighlightKey: Hashable {
    var source: String
    var palette: SyntaxPalette
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
