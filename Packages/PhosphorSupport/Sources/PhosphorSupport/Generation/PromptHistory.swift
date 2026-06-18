import Foundation

/// Extracts the chain of `/* prompt: ... */` comments at the top of a Phosphor
/// `.metal` source file. Used by the modify flow so successive prompts append
/// rather than overwrite.
///
/// Only comments appearing before the first non-comment-non-whitespace content
/// (typically the front-matter block) are considered — comments embedded inside
/// kernel bodies are ignored.
public enum PromptHistory {
    public static func extract(from source: String) -> [String] {
        var index = source.startIndex
        var prompts: [String] = []
        let openMarker = "/* prompt:"

        while index < source.endIndex {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
            guard index < source.endIndex else { break }
            let remainder = source[index...]

            if remainder.hasPrefix(openMarker) {
                let afterOpen = remainder.dropFirst(openMarker.count)
                guard let closeRange = afterOpen.range(of: "*/") else { break }
                let body = afterOpen[..<closeRange.lowerBound]
                prompts.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
                index = closeRange.upperBound
                continue
            }

            // Skip other leading block / line comments but don't record them.
            if remainder.hasPrefix("//") {
                if let newlineIndex = remainder.firstIndex(of: "\n") {
                    index = source.index(after: newlineIndex)
                    continue
                }
                break
            }
            if remainder.hasPrefix("/*") {
                let afterOpen = remainder.dropFirst(2)
                guard let closeRange = afterOpen.range(of: "*/") else { break }
                index = closeRange.upperBound
                continue
            }

            // Hit real content — stop.
            break
        }

        return prompts
    }
}
