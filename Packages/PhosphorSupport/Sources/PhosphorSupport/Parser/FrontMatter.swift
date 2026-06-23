import Foundation
import PhosphorModel
import TOMLKit

/// A source string plus its parsed front-matter configuration and any
/// diagnostics emitted during parsing or validation.
///
/// Construct with ``ParsedPhosphorSource/init(source:)`` (delegates to
/// ``PhosphorFrontMatter/parse(_:)``).
public struct ParsedPhosphorSource: Hashable, Sendable {
    /// The original, unmodified source string.
    public var originalSource: String
    /// The source with the front-matter block stripped, suitable for passing
    /// to the compiler / assembler.
    public var body: String
    /// The decoded configuration. Always present: when the source has no
    /// front-matter or the TOML fails to parse, this is a minimal default
    /// (`output = "image"`) and ``diagnostics`` / ``hasFrontMatter`` explain
    /// the situation.
    public var configuration: PhosphorConfiguration
    /// Front-matter parse and validation diagnostics. Empty when the source
    /// has no front-matter at all.
    public var diagnostics: [PhosphorDiagnostic]

    public init(
        originalSource: String,
        body: String,
        configuration: PhosphorConfiguration,
        diagnostics: [PhosphorDiagnostic],
        hasFrontMatter: Bool
    ) {
        self.originalSource = originalSource
        self.body = body
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.hasFrontMatter = hasFrontMatter
    }

    /// Convenience: parse a source string in one step.
    public init(source: String) {
        self = PhosphorFrontMatter.parse(source)
    }

    /// `true` if the source has a front-matter block (parsed or not).
    public var hasFrontMatter: Bool
}

/// Extracts and parses the `/* phosphor:environment ... */` TOML front-matter
/// block from a Phosphor source string.
///
/// The split is deliberate: callers may want to feed the cleaned source to
/// ``SourceAssembler/assemble(configuration:userSource:)`` separately, so we
/// don't bake the assembly step in here.
public enum PhosphorFrontMatter {
    /// Parses a source string into a ``ParsedPhosphorSource``.
    public static func parse(_ source: String) -> ParsedPhosphorSource {
        let fallback = PhosphorConfiguration(output: "image")
        guard let (block, body) = extractBlock(source) else {
            return ParsedPhosphorSource(originalSource: source, body: source, configuration: fallback, diagnostics: [], hasFrontMatter: false)
        }

        let toml: TOMLTable
        do {
            toml = try TOMLTable(string: block)
        } catch {
            return ParsedPhosphorSource(
                originalSource: source,
                body: body,
                configuration: fallback,
                diagnostics: [.frontMatterParse(extractTOMLErrorMessage(error), line: extractTOMLErrorLine(error))],
                hasFrontMatter: true
            )
        }

        let configuration: PhosphorConfiguration
        do {
            let decoder = TOMLDecoder()
            configuration = try decoder.decode(PhosphorConfiguration.self, from: toml)
        } catch {
            return ParsedPhosphorSource(
                originalSource: source,
                body: body,
                configuration: fallback,
                diagnostics: [.frontMatterParse("decode failed: \(error)", line: nil)],
                hasFrontMatter: true
            )
        }

        let validationDiagnostics = validate(configuration)
        return ParsedPhosphorSource(
            originalSource: source,
            body: body,
            configuration: configuration,
            diagnostics: validationDiagnostics,
            hasFrontMatter: true
        )
    }

    /// Finds a `/* phosphor:environment ... */` block near the top of the file.
    ///
    /// Returns the TOML body (between marker and closing `*/`) plus the source
    /// with the block removed, or `nil` if no block is found.
    ///
    /// "Near the top" means: whitespace, line comments (`// ...`), and other
    /// C-style block comments (`/* ... */` that are NOT the configuration
    /// marker) may appear before the front-matter block. This lets generated
    /// shaders prepend a `/* prompt: ... */` comment without breaking parsing.
    static func extractBlock(_ source: String) -> (block: String, body: String)? {
        var index = source.startIndex
        let openMarker = "/* phosphor:environment"
        while index < source.endIndex {
            // Skip whitespace.
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
            guard index < source.endIndex else { return nil }

            let remainder = source[index...]

            // Is this the front-matter marker?
            if remainder.hasPrefix(openMarker) {
                let afterOpen = remainder.dropFirst(openMarker.count)
                guard let closeRange = afterOpen.range(of: "*/") else { return nil }
                let blockText = afterOpen[..<closeRange.lowerBound]
                let afterClose = afterOpen[closeRange.upperBound...]
                return (String(blockText), String(afterClose))
            }

            // Skip a leading line comment.
            if remainder.hasPrefix("//") {
                if let newlineIndex = remainder.firstIndex(of: "\n") {
                    index = source.index(after: newlineIndex)
                    continue
                }
                return nil
            }

            // Skip a leading block comment that isn't the marker.
            if remainder.hasPrefix("/*") {
                let afterOpen = remainder.dropFirst(2)
                guard let closeRange = afterOpen.range(of: "*/") else { return nil }
                index = closeRange.upperBound
                continue
            }

            // Hit non-comment, non-whitespace content. No front-matter here.
            return nil
        }
        return nil
    }

    /// Best-effort extraction of a human-readable error message from a TOMLKit
    /// decode failure. TOMLKit errors are reasonably descriptive on their own
    /// but vary by type; we stringify and trim.
    private static func extractTOMLErrorMessage(_ error: Error) -> String {
        "\(error)"
    }

    /// Best-effort extraction of the offending line number. TOMLKit error
    /// types carry a `source` with a line attribute on parse errors. Returns
    /// nil if we can't dig it out.
    private static func extractTOMLErrorLine(_ error: Error) -> Int? {
        if let parseError = error as? TOMLParseError {
            return Int(parseError.source.begin.line)
        }
        return nil
    }
}
