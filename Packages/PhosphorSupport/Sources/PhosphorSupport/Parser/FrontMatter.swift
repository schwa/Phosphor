import Foundation
import TOMLKit

/// A source string plus its parsed front-matter environment and any
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
    /// The decoded environment, or `nil` if the source has no front-matter
    /// or the TOML failed to parse.
    public var environment: PhosphorEnvironment?
    /// Front-matter parse and validation diagnostics. Empty when the source
    /// has no front-matter at all.
    public var diagnostics: [PhosphorDiagnostic]

    public init(
        originalSource: String,
        body: String,
        environment: PhosphorEnvironment?,
        diagnostics: [PhosphorDiagnostic]
    ) {
        self.originalSource = originalSource
        self.body = body
        self.environment = environment
        self.diagnostics = diagnostics
    }

    /// Convenience: parse a source string in one step.
    public init(source: String) {
        self = PhosphorFrontMatter.parse(source)
    }

    /// `true` if the source had no front-matter block at all.
    public var hasFrontMatter: Bool { environment != nil || diagnostics.contains { diagnostic in
        if case .frontMatterParse = diagnostic { return true }return false
    } }
}

/// Extracts and parses the `/* phosphor:environment ... */` TOML front-matter
/// block from a Phosphor source string.
///
/// The split is deliberate: callers may want to feed the cleaned source to
/// ``SourceAssembler/assemble(environment:userSource:)`` separately, so we
/// don't bake the assembly step in here.
public enum PhosphorFrontMatter {
    /// Parses a source string into a ``ParsedPhosphorSource``.
    public static func parse(_ source: String) -> ParsedPhosphorSource {
        guard let (block, body) = extractBlock(source) else {
            return ParsedPhosphorSource(originalSource: source, body: source, environment: nil, diagnostics: [])
        }

        let toml: TOMLTable
        do {
            toml = try TOMLTable(string: block)
        } catch {
            return ParsedPhosphorSource(
                originalSource: source,
                body: body,
                environment: nil,
                diagnostics: [.frontMatterParse(extractTOMLErrorMessage(error), line: extractTOMLErrorLine(error))]
            )
        }

        let environment: PhosphorEnvironment
        do {
            let decoder = TOMLDecoder()
            environment = try decoder.decode(PhosphorEnvironment.self, from: toml)
        } catch {
            return ParsedPhosphorSource(
                originalSource: source,
                body: body,
                environment: nil,
                diagnostics: [.frontMatterParse("decode failed: \(error)", line: nil)]
            )
        }

        let validationDiagnostics = validate(environment)
        return ParsedPhosphorSource(
            originalSource: source,
            body: body,
            environment: environment,
            diagnostics: validationDiagnostics
        )
    }

    /// Finds a `/* phosphor:environment ... */` block near the top of the file.
    ///
    /// Returns the TOML body (between marker and closing `*/`) plus the source
    /// with the block removed, or `nil` if no block is found.
    ///
    /// "Near the top" means: whitespace, line comments (`// ...`), and other
    /// C-style block comments (`/* ... */` that are NOT the environment
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
