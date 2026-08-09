import SwiftTreeSitter
import SwiftUI

/// Turns source text into a styled `AttributedString` by walking a
/// tree-sitter parse tree and coloring node ranges.
public enum SyntaxHighlighter {
    /// Highlights `source` as `language`, colored by `palette`.
    ///
    /// Order matters: the flat foreground and the per-line backdrop are laid
    /// down first so unclassified characters (punctuation, whitespace) still
    /// get styled, then the outer grammar's tokens, then any embedded regions
    /// on top.
    public static func highlight(
        _ source: String,
        language: SourceLanguage,
        palette: SyntaxPalette
    ) throws -> AttributedString {
        var attributed = AttributedString(source)

        let fullRange = attributed.startIndex..<attributed.endIndex
        attributed[fullRange].foregroundColor = palette.foreground

        if let backdrop = palette.tokenBackground {
            applyLineBackdrop(to: &attributed, source: source, color: backdrop)
        }

        try apply(language, to: &attributed, source: source, baseUTF16Offset: 0, palette: palette)

        for region in language.embeddedRegions(source) {
            let text = String(source[region.range])
            let offset = source.utf16.distance(from: source.startIndex, to: region.range.lowerBound)
            try apply(region.language, to: &attributed, source: text, baseUTF16Offset: offset, palette: palette)
        }

        return attributed
    }

    private static func apply(
        _ language: SourceLanguage,
        to attributed: inout AttributedString,
        source: String,
        baseUTF16Offset: Int,
        palette: SyntaxPalette
    ) throws {
        let parser = Parser()
        try parser.setLanguage(language.language)
        guard let tree = parser.parse(source), let root = tree.rootNode else { return }
        walk(
            node: root,
            attributed: &attributed,
            baseUTF16Offset: baseUTF16Offset,
            roles: language.roles,
            palette: palette
        )
    }

    private static func walk(
        node: Node,
        attributed: inout AttributedString,
        baseUTF16Offset: Int,
        roles: [String: TokenRole],
        palette: SyntaxPalette
    ) {
        if let role = roles[node.nodeType ?? ""], let style = palette.style(for: role) {
            let nsRange = NSRange(
                location: node.range.location + baseUTF16Offset,
                length: node.range.length
            )
            if let characterRange = Range(nsRange, in: attributed) {
                attributed[characterRange].foregroundColor = style.color
                if style.isItalic {
                    attributed[characterRange].font = .system(.body, design: .monospaced).italic()
                }
            }
        }
        node.enumerateChildren { child in
            walk(
                node: child,
                attributed: &attributed,
                baseUTF16Offset: baseUTF16Offset,
                roles: roles,
                palette: palette
            )
        }
    }

    /// Sets `backgroundColor` on every character of every line, leaving the
    /// newlines uncolored so the backdrop doesn't bleed past the line edge.
    private static func applyLineBackdrop(
        to attributed: inout AttributedString,
        source: String,
        color: Color
    ) {
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let newlineIndex = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
            if cursor < newlineIndex {
                let nsRange = NSRange(cursor..<newlineIndex, in: source)
                if let range = Range(nsRange, in: attributed) {
                    attributed[range].backgroundColor = color
                }
            }
            cursor = newlineIndex < source.endIndex
                ? source.index(after: newlineIndex)
                : source.endIndex
        }
    }
}

extension Range where Bound == AttributedString.Index {
    init?(_ range: NSRange, in string: AttributedString) {
        let base = String(string.characters)
        guard
            let fromUTF16 = base.utf16.index(base.utf16.startIndex, offsetBy: range.location, limitedBy: base.utf16.endIndex),
            let toUTF16 = base.utf16.index(fromUTF16, offsetBy: range.length, limitedBy: base.utf16.endIndex),
            let from = AttributedString.Index(fromUTF16, within: string),
            let to = AttributedString.Index(toUTF16, within: string)
        else {
            return nil
        }
        self = from..<to
    }
}
