import Foundation
import TOMLKit

/// Extracts and parses the `/* phosphor:environment ... */` TOML front-matter
/// block from a Phosphor source string.
///
/// Returns the parsed environment, the source string with the front-matter
/// stripped, and any diagnostics produced along the way.
///
/// The split is deliberate: callers may want to feed the cleaned source to
/// ``SourceAssembler/assemble(environment:userSource:)`` separately, so we
/// don't bake the assembly step in here.
public enum PhosphorFrontMatter {
    /// Parses a source string into an environment plus the user-source body.
    ///
    /// - Returns a tuple of `(environment, body, diagnostics)`. `environment`
    ///   is `nil` if the source has no front-matter, or if the TOML failed to
    ///   parse / validate. `body` is the source with the front-matter block
    ///   stripped (so it can be fed to the compiler / assembler).
    public static func parse(_ source: String) -> (environment: PhosphorEnvironment?, body: String, diagnostics: [PhosphorDiagnostic]) {
        guard let (block, body) = extractBlock(source) else {
            return (nil, source, [])
        }

        let toml: TOMLTable
        do {
            toml = try TOMLTable(string: block)
        } catch {
            return (nil, body, [.frontMatterParse(extractTOMLErrorMessage(error), line: extractTOMLErrorLine(error))])
        }

        let environment: PhosphorEnvironment
        do {
            let decoder = TOMLDecoder()
            environment = try decoder.decode(PhosphorEnvironment.self, from: toml)
        } catch {
            return (nil, body, [.frontMatterParse("decode failed: \(error)", line: nil)])
        }

        let validationDiagnostics = validate(environment)
        return (environment, body, validationDiagnostics)
    }

    /// Finds a `/* phosphor:environment ... */` block at the top of the file.
    ///
    /// Returns the TOML body (between marker and closing `*/`) plus the source
    /// with the block removed, or `nil` if no block is present at the top.
    ///
    /// "At the top" means: zero or more whitespace-only / blank lines may
    /// precede the block, but no other content.
    static func extractBlock(_ source: String) -> (block: String, body: String)? {
        let leadingWhitespace = source.prefix { $0.isWhitespace }
        let afterWhitespace = source[leadingWhitespace.endIndex...]
        let openMarker = "/* phosphor:environment"
        guard afterWhitespace.hasPrefix(openMarker) else { return nil }
        let afterOpen = afterWhitespace.dropFirst(openMarker.count)
        guard let closeRange = afterOpen.range(of: "*/") else { return nil }
        let blockText = afterOpen[..<closeRange.lowerBound]
        let afterClose = afterOpen[closeRange.upperBound...]
        return (String(blockText), String(afterClose))
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
