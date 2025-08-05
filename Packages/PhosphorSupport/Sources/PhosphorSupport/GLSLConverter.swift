import SwiftTreeSitter
import TreeSitterCPP
import Foundation

public struct GLSLConverter {

    public init() {

    }

    public func convert(source: String) throws -> String {
        let cppConfig = try LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        let parser = Parser()
        try parser.setLanguage(cppConfig.language)
        guard let tree = parser.parse(source) else {
            fatalError()
        }
//        func walk(node: Node, depth: Int = 0) {
//            let indent = String(repeating: "  ", count: depth)
//            print("\(indent)\(node.nodeType ?? "<nil>") \(source.substring(from: node)) \(node.sExpressionString)")
//            node.enumerateChildren { child in
//                walk(node: child, depth: depth + 1)
//            }
//        }
//        walk(node: tree.rootNode!)

        struct Transform {
            var query: String
            var closure: (QueryMatch) -> [(NSRange, String)]
        }

        let transforms: [Transform] = [
            Transform(query: """
                (type_identifier) @type
            """) { match in
                assert(match.captures(named: "type").count == 1)
                let capture = match.captures(named: "type")[0]
                let identifier = source[capture.range]
                switch identifier {
                case "vec3":
                    return [(capture.range, "float3")]
                default:
                    return []
                }
            },

            Transform(query: """
                (call_expression
                    function: (identifier) @func
                    arguments: (argument_list) @args)
            """) { match in
                assert(match.captures(named: "func").count == 1)
                let functionCapture = match.captures(named: "func")[0]
                let functionName = source[functionCapture.range]
                switch functionName {
                case "vec3":
                    return [(functionCapture.range, "float3")]
                default:
                    return []
                }
            },


            Transform(query: """
                (field_expression
                  field: (field_identifier) @FIELD)
            """) { match in
                assert(match.captures(named: "FIELD").count == 1)
                let capture = match.captures(named: "FIELD")[0]
                let identifier = source[capture.range]
                switch identifier {
                case "xxxx":
                    return [(capture.range, "xxxx()")]
                default:
                    return []
                }
            }
        ]

        let queries = transforms.map { $0.query }.joined(separator: "\n")
        let q = try Query(language: cppConfig.language, data: queries.data(using: .utf8)!)
        let cursor = q.execute(in: tree)

        var replacements: [(NSRange, String)] = []

        for match in cursor {
            let transform = transforms[match.patternIndex]
            replacements.append(contentsOf: transform.closure(match))
        }

        let reversedReplacements = replacements.sorted { $0.0.lowerBound > $1.0.lowerBound }
        var result = source
        for (range, replacement) in reversedReplacements {
            guard let range = Range(range, in: source) else {
                fatalError("Invalid range: \(range)")
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

extension String {

    subscript(range: NSRange) -> Substring {
        guard let range = Range(range, in: self) else {
            fatalError("Invalid range: \(range)")
        }
        return self[range]
    }


    func substring(from: Node) -> Substring {
        let nsRange = from.range
        guard let range = Range(nsRange, in: self) else {
            fatalError()
        }
        return self[range]
    }
}

