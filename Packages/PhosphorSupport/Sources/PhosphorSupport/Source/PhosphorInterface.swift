import Foundation
import SwiftTreeSitter
import TreeSitterCPP

/// Produces a *declarations-only* view of the static `Phosphor.h` prelude:
/// every helper function definition has its body removed, leaving the
/// signature plus its doc comment, while constants, macros, and typedefs are
/// kept verbatim.
///
/// This is what the shader generator shows the model (#87): it should know
/// what helpers exist without being shown — or confused by — their
/// implementations. The interface is derived at runtime from the single
/// source of truth (`Phosphor.h`) via tree-sitter, so it can never drift.
public enum PhosphorInterface {
    /// The interface text, computed once and cached for the process.
    public static var source: String { cached }

    private static let cached: String = build()

    private static func build() -> String {
        let header = PhosphorHeader.staticHelperSource
        guard !header.isEmpty else { return "" }
        return strippingFunctionBodies(from: header)
    }

    /// Parses `source` as C++ and replaces each function definition's body
    /// (`compound_statement`) with `;`, preserving everything else. Falls
    /// back to the original source if parsing fails.
    static func strippingFunctionBodies(from source: String) -> String {
        guard let language = try? cppLanguage(),
              let parser = try? makeParser(language),
              let tree = parser.parse(source),
              let root = tree.rootNode else {
            return source
        }

        // Collect the UTF-16 ranges of every function body, outermost first.
        var bodyRanges: [NSRange] = []
        collectFunctionBodies(node: root, into: &bodyRanges)

        guard !bodyRanges.isEmpty else { return source }

        // Splice from the end so earlier offsets stay valid. Each body
        // (`{ ... }`) becomes `;`.
        let mutable = NSMutableString(string: source)
        for range in bodyRanges.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: ";")
        }

        // Tidy up: `inline` is a definition specifier with no place on a bare
        // declaration, and tree-sitter leaves a space before the spliced `;`.
        var result = mutable as String
        result = result.replacingOccurrences(
            of: #"(?m)^inline\s+"#, with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(of: ") ;", with: ");")
        result = result.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func collectFunctionBodies(node: Node, into ranges: inout [NSRange]) {
        if node.nodeType == "function_definition" {
            node.enumerateChildren { child in
                if child.nodeType == "compound_statement" {
                    ranges.append(child.range)
                }
            }
            // Bodies don't nest function definitions in this file; no need to
            // recurse into a definition we're already stripping.
            return
        }
        node.enumerateChildren { child in
            collectFunctionBodies(node: child, into: &ranges)
        }
    }

    private static func cppLanguage() throws -> Language {
        try LanguageConfiguration(tree_sitter_cpp(), name: "cpp").language
    }

    private static func makeParser(_ language: Language) throws -> Parser {
        let parser = Parser()
        try parser.setLanguage(language)
        return parser
    }
}
