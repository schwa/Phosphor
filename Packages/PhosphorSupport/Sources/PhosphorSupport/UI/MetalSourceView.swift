import SwiftTreeSitter
import SwiftTreeSitterLayer
import SwiftUI
import TreeSitterCPP

/// Read-only, syntax-highlighted view of a Metal source string.
///
/// Uses the tree-sitter C++ grammar (MSL is close enough to C++ that the
/// grammar gives useful coloring out of the box). Highlighting kicks in on
/// the first appearance and on source changes.
public struct MetalSourceView: View {
    public let text: String

    @State private var attributedText: AttributedString = ""

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(attributedText)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: text) {
                attributedText = AttributedString(text)
                if let highlighted = try? Self.format(text) {
                    attributedText = highlighted
                }
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
