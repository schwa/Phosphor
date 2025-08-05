import SwiftUI
import SwiftTreeSitter
import TreeSitterCPP

struct ContentView: View {

    @State
    var source = """
    a.zyx = vec3(0, 1, 2);
    vec3 b = a.zyx;
    """

    @State
    var convertedSource: String = ""

    @State
    var tree: MutableTree?

    let parser: Parser
    let language: Language

    init() {
        let cppConfig = try! LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        parser = Parser()
        language = cppConfig.language
        try! parser.setLanguage(language)
    }

    var body: some View {
        HSplitView {
            VSplitView {
                LabeledContent("Source") {
                    TextEditor(text: $source)
                        .monospaced()
                }
                LabeledContent("Converted Source") {
                    TextEditor(text: .constant(convertedSource))
                        .monospaced()
                }
            }
            Group {
                if let tree {
                    LabeledContent("Tree") {
                        TreeView(tree: tree.copy()!)
                    }
                }
            }
            Group {
                if let tree {
                    QueryView(language: language, tree: tree.copy()!)
                }
            }


        }
        .labeledContentStyle(MyLabeledContentStyle())
        .onChange(of: source, initial: true) {
            try! sourceDidChange()
        }
    }

    func sourceDidChange() throws {
        guard let tree = parser.parse(source) else {
            fatalError()
        }
        self.tree = tree

        (convertedSource, _) = try! GLSLConverter().convert(source: source)
    }

}


struct TreeView: View {
    let tree: Tree

    @State
    var selection: Node.ID?

    var body: some View {
        VStack {
            List([tree.rootNode!], children: \.children, selection: $selection) { node in
                Text("\(node.nodeType ?? "<nil>") \(String(describing: node.range))")
            }
            if let selection {
                Text("#\(selection)").monospacedDigit()
            }
        }
    }

}

struct QueryView: View {
    let language: Language
    let tree: Tree

    @State
    var queryString = """
    (assignment_expression
        (field_expression
            (identifier) @ID
            (field_identifier) @FIELD_ID
        )
        ("=")
        (_) @EXPR
    ) @ALL
    """

    @State
    var matches: [QueryMatch] = []

    var body: some View {
        VSplitView {
            LabeledContent("Query") {
                TextEditor(text: $queryString)
                    .monospaced()
                    .autocorrectionDisabled()
                    
            }
            LabeledContent("Matches") {
                List(Array(matches.enumerated()), id: \.element.id) { (offset, match) in
                    HStack(alignment: .top) {
                        Text("\(offset, format: .number)")
                        Text(String(describing: match)).monospaced()
                    }
                }

            }
        }
        .onChange(of: tree.rootNode?.id, initial: true) {
            matches = []
            try? queryDidChange()
        }
        .onChange(of: queryString, initial: true) {
            matches = []
            try? queryDidChange()
        }
    }

    func queryDidChange() throws {
        let q = try Query(language: language, data: queryString.data(using: .utf8)!)
        let cursor = q.execute(in: tree)

        matches = Array(cursor)
//        for match in cursor {
////            let transform = transforms[match.patternIndex]
////            replacements.append(contentsOf: transform.closure(match))
//        }
//

    }

}


extension Node: @retroactive Identifiable {

}

extension Node {
    var children: [Node]? {
        var children: [Node] = []
        enumerateChildren { child in
            children.append(child)
        }
        return children.count > 0 ? children : nil
    }
}

extension QueryMatch: @retroactive Identifiable {
}

struct MyLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) {
            configuration.label
                .font(.title)
            configuration.content
        }
        .padding(2)
    }
}
