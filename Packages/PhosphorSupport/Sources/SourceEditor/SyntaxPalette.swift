import SwiftUI

/// How one ``TokenRole`` is drawn.
public struct TokenStyle: Hashable, Sendable {
    public var color: Color
    public var isItalic: Bool

    public init(_ color: Color, italic: Bool = false) {
        self.color = color
        self.isItalic = italic
    }
}

/// Maps ``TokenRole`` values onto colors for ``SourceEditorView``.
///
/// Roles with no entry fall back to ``foreground``, so a palette only has to
/// name the roles it cares about and a language can introduce new roles
/// without breaking existing palettes.
public struct SyntaxPalette: Hashable, Sendable {
    /// Foreground for any character the highlighter didn't classify
    /// (punctuation, operators, raw whitespace) or whose role has no style.
    public var foreground: Color
    public var styles: [TokenRole: TokenStyle]
    /// Optional translucent backdrop drawn behind every line of code. `nil`
    /// means the natural editor background shows through. Used by the overlay
    /// layout to keep tokens legible against a live render.
    public var tokenBackground: Color?

    public init(
        foreground: Color,
        styles: [TokenRole: TokenStyle],
        tokenBackground: Color? = nil
    ) {
        self.foreground = foreground
        self.styles = styles
        self.tokenBackground = tokenBackground
    }

    public func style(for role: TokenRole) -> TokenStyle? {
        styles[role]
    }

    /// Returns a copy with `tokenBackground` replaced.
    public func withTokenBackground(_ color: Color?) -> Self {
        var copy = self
        copy.tokenBackground = color
        return copy
    }

    /// Default palette for an editor pane on a system text-background color.
    public static let `default` = Self(
        foreground: .primary,
        styles: [
            .comment: TokenStyle(.green, italic: true),
            .identifier: TokenStyle(.blue),
            .number: TokenStyle(.orange),
            .type: TokenStyle(.purple),
            .keyword: TokenStyle(.pink),
            .call: TokenStyle(.teal),
            .key: TokenStyle(.blue),
            .string: TokenStyle(.red),
            .boolean: TokenStyle(.pink),
            .heading: TokenStyle(.purple)
        ]
    )

    /// Light, slightly desaturated colors that read well on a dark background.
    public static let dark = Self(
        foreground: Color(white: 0.85),
        styles: [
            .comment: TokenStyle(Color(red: 0.45, green: 0.7, blue: 0.45), italic: true),
            .identifier: TokenStyle(Color(red: 0.55, green: 0.8, blue: 1.0)),
            .number: TokenStyle(Color(red: 1.0, green: 0.75, blue: 0.4)),
            .type: TokenStyle(Color(red: 0.85, green: 0.6, blue: 1.0)),
            .keyword: TokenStyle(Color(red: 1.0, green: 0.5, blue: 0.7)),
            .call: TokenStyle(Color(red: 0.5, green: 0.95, blue: 0.95)),
            .key: TokenStyle(Color(red: 0.55, green: 0.8, blue: 1.0)),
            .string: TokenStyle(Color(red: 1.0, green: 0.7, blue: 0.55)),
            .boolean: TokenStyle(Color(red: 1.0, green: 0.5, blue: 0.7)),
            .heading: TokenStyle(Color(red: 0.85, green: 0.6, blue: 1.0))
        ]
    )

    /// ``dark`` with a translucent backdrop behind every line, for editors
    /// drawn on top of other content.
    public static let darkWithBackdrop = Self.dark.withTokenBackground(.black.opacity(0.6))
}
