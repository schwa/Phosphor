import SwiftUI
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitterCPP

struct MetalTextEditor: View {
    @Binding var text: String
    @State private var attributedText: AttributedString = ""
    @State private var tree: MutableTree?

    let cppConfig: LanguageConfiguration
    let parser: Parser

    init(text: Binding<String>) {
        self._text = text

        cppConfig = try! LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        parser = Parser()
        try! parser.setLanguage(cppConfig.language)
        tree = parser.parse(text.wrappedValue)
    }

    var body: some View {
        TextEditor(text: $attributedText)
        .onChange(of: text, initial: true) {
            attributedText = AttributedString(text)
            Task {
                print("Formatting starting")
                attributedText = try! format(text)
                print("Formatting completed")
            }
        }
        .onChange(of: attributedText) {
            text = String(attributedText.characters)
        }
    }

    func format(_ source: String) throws -> AttributedString {
        var attributedString = AttributedString(source)
        // TODO: We chould re-use the tree - but this breaks is the source changes radically.
        // tree = parser.parse(tree: tree, string: source)
        tree = parser.parse(source)
        guard let rootNode = tree?.rootNode else {
            return attributedString
        }
        func walk(node: Node, depth: Int = 0) {
//            let indent = String(repeating: "  ", count: depth)
//            print("\(indent)\(node.nodeType ?? "<nil>")")

            let nsRange = node.range
            guard let characterRange = Range(nsRange, in: attributedString) else {
                return
            }

            switch node.nodeType {
            case "comment":
                attributedString[characterRange].foregroundColor = .green
            case "identifier":
                attributedString[characterRange].foregroundColor = .blue
            case "number_literal":
                attributedString[characterRange].foregroundColor = .orange
            case "primitive_type", "type_identifier", "template_type":
                attributedString[characterRange].foregroundColor = .purple
            case "return", "if":
                attributedString[characterRange].foregroundColor = .magenta
            case "call_expression":
                attributedString[characterRange].foregroundColor = .teal
            case "binary_expression":
                attributedString[characterRange].foregroundColor = .red
            default:
                break
            }

            node.enumerateChildren { child in
                walk(node: child, depth: depth + 1)
            }
        }
        walk(node: rootNode)
        return attributedString
    }
}

extension Range where Bound == AttributedString.Index {
    init?(_ range: NSRange, in string: AttributedString) {
        // Convert AttributedString to String to get proper indices
        let base = String(string.characters)
        guard let fromUTF16 = base.utf16.index(base.utf16.startIndex, offsetBy: range.location, limitedBy: base.utf16.endIndex),
              let toUTF16 = base.utf16.index(fromUTF16, offsetBy: range.length, limitedBy: base.utf16.endIndex),
              let from = AttributedString.Index(fromUTF16, within: string),
              let to = AttributedString.Index(toUTF16, within: string) else {
            return nil
        }
        self = from..<to
    }
}
