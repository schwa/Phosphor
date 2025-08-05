import SwiftTreeSitter
import TreeSitterCPP
import Foundation

public struct GLSLConverter {

    public init() {

    }

    public func convert(source: String) throws -> (String, String) {

        struct Transform {
            var query: String
            var closure: (String, QueryMatch) -> [(NSRange, String)]
        }



        let transforms: [Transform] = [
            Transform(query: """
                (type_identifier) @type
            """) { source, match in
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
            """) { source, match in
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
            (assignment_expression
                (field_expression
                    (identifier) @ID
                    (field_identifier) @FIELD_ID
                )
                ("=")
                (_) @EXPR
            ) @ALL
            """) { source, match in
                assert(match.captures(named: "ID").count == 1)
                assert(match.captures(named: "FIELD_ID").count == 1)
                assert(match.captures(named: "EXPR").count == 1)
                assert(match.captures(named: "ALL").count == 1)
                let id = source[match.captures(named: "ID")[0].range]
                let fieldId = source[match.captures(named: "FIELD_ID")[0].range]
                switch fieldId {
                case "xzy", "yxz", "yzx", "zxy", "zyx":
                    break
                default:
                    return []
                }
                let expr = source[match.captures(named: "EXPR")[0].range]
                let allRange = match.captures(named: "ALL")[0].range
                return [
                    (allRange, "\(id) = swizzle_set_\(fieldId)(\(expr))")
                ]
            },

            Transform(query: """
            (field_expression
                (identifier) @ID
                (field_identifier) @FIELD_ID
            ) @ALL
            """) { source, match in
                assert(match.captures(named: "ID").count == 1)
                assert(match.captures(named: "FIELD_ID").count == 1)
                assert(match.captures(named: "ALL").count == 1)
                let id = source[match.captures(named: "ID")[0].range]
                let fieldId = source[match.captures(named: "FIELD_ID")[0].range]
                switch fieldId {
                case "xyz", "xzy", "yxz", "yzx", "zxy", "zyx":
                    break
                default:
                    return []
                }
                let allRange = match.captures(named: "ALL")[0].range
                return [
                    (allRange, "swizzle_get_\(fieldId)(\(id))")
                ]
            }
        ]

/*

 float3 swizzle_set_zyx(float3 v) {
    return float3(v.z, v.y, v.x);
 }

 float3 swizzle_get_zyx(float3 v) {
    return float3(v.z, v.y, v.x);
}
 */


        let config = try LanguageConfiguration(tree_sitter_cpp(), name: "cpp")
        var source = source
        let parser = Parser()
        try parser.setLanguage(config.language)

        var tree: MutableTree?
        for transform in transforms {
//            tree = parser.parse(tree: tree, string: source)
            tree = parser.parse(source)
            guard let tree else {
                fatalError()
            }
            let q = try Query(language: config.language, data: transform.query.data(using: .utf8)!)
            let cursor = q.execute(in: tree)
            var replacements: [(NSRange, String)] = []
            for match in cursor {
                replacements.append(contentsOf: transform.closure(source, match))
            }
            let reversedReplacements = replacements.sorted { $0.0.lowerBound > $1.0.lowerBound }
            for (range, replacement) in reversedReplacements {
                guard let range = Range(range, in: source) else {
                    fatalError("Invalid range: \(range)")
                }
                source.replaceSubrange(range, with: replacement)
            }
        }
        return (source, "")
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

