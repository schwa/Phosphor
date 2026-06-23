import Foundation
import PhosphorModel

/// Assembles a full Metal compile unit for an configuration by:
///
/// 1. Building the synthetic `Phosphor.h` content (see ``PhosphorHeader``).
/// 2. Stripping any literal `#include "Phosphor.h"` lines from the user's source.
/// 3. Stripping the `/* phosphor:environment ... */` front-matter block if present.
/// 4. Injecting per-pass `#define Uniforms Pass_<id>_Uniforms` /
///    `#define Textures Pass_<id>_Textures` blocks immediately before each
///    `kernel void <passid>` declaration so the user can write the
///    canonical names in their kernel body.
/// 5. Concatenating header + (transformed) user source.
enum SourceAssembler {
    static func assemble(configuration: PhosphorConfiguration, userSource: String) -> String {
        let cleaned = stripFrontMatter(stripPhosphorHeaderInclude(userSource))
        let injected = injectPassDefines(into: cleaned, config: configuration)
        let prelude = PhosphorHeader.source(for: configuration)
        return prelude + "\n" + injected
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

    /// For each `kernel void <passid>(` in `source` that matches a declared
    /// pass id, prepends `#define Uniforms Pass_<id>_Uniforms` and
    /// `#define Textures Pass_<id>_Textures`. Between two consecutive
    /// kernels the previous pass's defines are undef'd first, so the
    /// definitions don't leak across kernels.
    static func injectPassDefines(into source: String, config: PhosphorConfiguration) -> String {
        guard !config.passes.isEmpty else { return source }

        // Build a list of (range, passID) for each `kernel void <id>` match.
        let passIDs = config.passes.map(\.id.raw)
        var hits: [(range: NSRange, passID: String)] = []
        for passID in passIDs {
            let pattern = "\\bkernel\\s+void\\s+\(NSRegularExpression.escapedPattern(for: passID))\\s*\\("
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsSource = source as NSString
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { match, _, _ in
                if let match {
                    hits.append((match.range, passID))
                }
            }
        }
        guard !hits.isEmpty else { return source }
        hits.sort { $0.range.location < $1.range.location }

        // Splice in defines + undefs around each kernel header.
        var out = ""
        var cursor = source.startIndex
        var sawPreviousPass = false
        for hit in hits {
            guard let hitStart = Range(NSRange(location: hit.range.location, length: 0), in: source) else { continue }
            out += source[cursor..<hitStart.lowerBound]
            if sawPreviousPass {
                out += "#undef Uniforms\n#undef Textures\n"
            }
            out += "#define Uniforms Pass_\(hit.passID)_Uniforms\n"
            out += "#define Textures Pass_\(hit.passID)_Textures\n"
            sawPreviousPass = true
            cursor = hitStart.lowerBound
        }
        out += source[cursor...]
        return out
    }
}
