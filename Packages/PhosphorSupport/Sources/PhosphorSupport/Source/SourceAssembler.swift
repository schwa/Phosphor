import Foundation

/// Assembles a full Metal compile unit for an environment by:
///
/// 1. Building the synthetic `Phosphor.h` content (see ``PhosphorHeader``).
/// 2. Stripping any literal `#include "Phosphor.h"` lines from the user's source.
/// 3. Stripping the `/* phosphor:environment ... */` front-matter block if present.
/// 4. Concatenating header + cleaned user source.
///
/// The resulting string is what gets passed to `device.makeLibrary(source:)`.
public enum SourceAssembler {
    public static func assemble(environment: PhosphorEnvironment, userSource: String) -> String {
        let cleaned = stripFrontMatter(stripPhosphorHeaderInclude(userSource))
        let prelude = PhosphorHeader.source(for: environment)
        return prelude + "\n" + cleaned
    }

    /// Removes any line equivalent to `#include "Phosphor.h"`. Whitespace
    /// before `#` is tolerated.
    static func stripPhosphorHeaderInclude(_ source: String) -> String {
        let pattern = #"^\s*#\s*include\s*"Phosphor\.h"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
    }

    /// Removes a `/* phosphor:environment ... */` front-matter block if it
    /// is the first non-whitespace content of the file.
    ///
    /// Only strips at most one block, and only if it appears at the top.
    static func stripFrontMatter(_ source: String) -> String {
        let trimmed = source.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix("/* phosphor:environment") else { return source }
        guard let endRange = trimmed.range(of: "*/") else { return source }
        let afterEnd = trimmed[endRange.upperBound...]
        return String(afterEnd)
    }
}
