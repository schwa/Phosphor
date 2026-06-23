import Foundation
import PhosphorModel
import TOMLKit

/// Serializes a ``PhosphorConfiguration`` to the TOML body text that lives
/// inside the `/* phosphor:environment ... */` block. The output matches
/// the hand-written `Examples/` style (sectional top-level array-of-tables
/// like `[[resources]]`, inline leaf records like `spec = { ... }`).
public enum FrontMatterFormatter {
    /// Encodes the configuration and returns just the TOML body (no outer
    /// `/* phosphor:environment ... */` wrapper).
    public static func encodeBody(_ configuration: PhosphorConfiguration) throws -> String {
        var encoder = TOMLEncoder()
        encoder.options = [.allowMultilineStrings, .relaxedFloatPrecision, .indentations]
        let rootTable: TOMLTable = try encoder.encode(configuration)
        inlineNestedTables(rootTable, depth: 0)
        return rootTable.convert(to: .toml, options: encoder.options)
    }

    /// Reformats `source` in place: parses its front-matter, re-encodes the
    /// configuration, splices the new front-matter block back in. The kernel
    /// body and any prompt-history comments above the block are preserved
    /// verbatim. Returns the unmodified source if there's no parseable
    /// front-matter.
    public static func reformat(_ source: String) -> String {
        let parsed = ParsedPhosphorSource(source: source)
        guard parsed.hasFrontMatter else { return source }
        guard let toml = try? encodeBody(parsed.configuration) else { return source }

        // Find the original block and replace it. Mirror PhosphorFrontMatter's
        // tolerance of leading whitespace and unrelated `// ...` / `/* ... */`
        // comments above the marker.
        let openMarker = "/* phosphor:environment"
        guard let openRange = source.range(of: openMarker) else { return source }
        guard let closeRange = source.range(of: "*/", range: openRange.upperBound..<source.endIndex) else {
            return source
        }
        let prefix = source[..<openRange.lowerBound]
        let suffix = source[closeRange.upperBound...]
        // Ensure the closing `*/` lands on its own line: trim any trailing
        // whitespace from the TOML body, then re-add exactly one newline.
        let body = toml.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)/* phosphor:environment\n\(body)\n*/\(suffix)"
    }

    /// Wraps a TOML body string in the standard front-matter block with
    /// `*/` on its own line. Used by ``GeneratedShader/toMetalSource(prompts:)``
    /// to keep generated and reformatted shaders consistent.
    public static func wrapFrontMatter(body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "/* phosphor:environment\n\(trimmed)\n*/"
    }

    /// Walks the encoded TOML and marks deep sub-tables as inline so
    /// TOMLKit emits them as `key = { ... }` rather than splitting into
    /// `[parent.child]` sections. See ``GeneratedShader/toMetalSource(prompts:)``
    /// for the rule.
    private static func inlineNestedTables(_ table: TOMLTable, depth: Int) {
        if depth >= 2 {
            table.inline = true
        }
        for (_, value) in table {
            if let nested = value.table {
                inlineNestedTables(nested, depth: depth + 1)
            } else if let array = value.array {
                inlineArrayMembers(array, depth: depth)
            }
        }
    }

    private static func inlineArrayMembers(_ array: TOMLArray, depth: Int) {
        for element in array {
            if let nested = element.table {
                inlineNestedTables(nested, depth: depth + 1)
            } else if let inner = element.array {
                inlineArrayMembers(inner, depth: depth + 1)
            }
        }
    }
}
