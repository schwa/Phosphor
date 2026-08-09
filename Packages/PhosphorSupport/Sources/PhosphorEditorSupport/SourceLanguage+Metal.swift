import SourceEditor
import SwiftTreeSitter
import TreeSitterCPP
import TreeSitterTOML

public extension SourceLanguage {
    /// TOML, as used by Phosphor's front-matter block.
    static let toml = SourceLanguage(
        id: "toml",
        language: Language(tree_sitter_toml()),
        roles: [
            "comment": .comment,
            "bare_key": .key,
            "dotted_key": .key,
            "string": .string,
            "integer": .number,
            "float": .number,
            "boolean": .boolean,
            "table_header": .heading,
            "array_table_header": .heading
        ]
    )

    /// Metal shader source, highlighted with the C++ grammar, with the
    /// `/* phosphor:environment ... */` front-matter body re-highlighted as
    /// TOML.
    static let metal = SourceLanguage(
        id: "metal",
        language: Language(tree_sitter_cpp()),
        roles: [
            "comment": .comment,
            "identifier": .identifier,
            "number_literal": .number,
            "primitive_type": .type,
            "type_identifier": .type,
            "template_type": .type,
            "return": .keyword,
            "if": .keyword,
            "call_expression": .call
        ]
    ) { source in
        guard let range = frontMatterTOMLRange(in: source) else { return [] }
        return [EmbeddedRegion(range: range, language: .toml)]
    }
}

/// Returns the range, in `source`, of the TOML body inside the
/// `/* phosphor:environment ... */` block: just after the marker, up to but
/// not including the closing `*/`. Mirrors `PhosphorFrontMatter.extractBlock`'s
/// rules but as offsets in the original source, not the trimmed view.
private func frontMatterTOMLRange(in source: String) -> Range<String.Index>? {
    let openMarker = "/* phosphor:environment"
    guard let openRange = source.range(of: openMarker) else { return nil }
    let afterMarker = openRange.upperBound
    guard let closeRange = source.range(of: "*/", range: afterMarker..<source.endIndex) else {
        return nil
    }
    return afterMarker..<closeRange.lowerBound
}
