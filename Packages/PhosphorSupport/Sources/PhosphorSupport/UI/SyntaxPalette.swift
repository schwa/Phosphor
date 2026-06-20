import SwiftUI

/// Color palette for ``MetalSourceView`` syntax highlighting.
///
/// Holds one ``Color`` per token category. Cover both Metal (C++) and
/// the front-matter TOML; categories that don't apply on one side are
/// simply ignored by that side's walker.
public struct SyntaxPalette: Hashable, Sendable {
    /// Foreground for any character not specifically recognized by the
    /// walker (punctuation, operators, raw whitespace, etc.).
    public var foreground: Color
    public var comment: Color
    public var identifier: Color
    public var number: Color
    public var type: Color
    public var keyword: Color
    public var callExpression: Color

    // TOML-specific (front-matter)
    public var tomlKey: Color
    public var tomlString: Color
    public var tomlNumber: Color
    public var tomlBoolean: Color
    public var tomlTableHeader: Color

    /// Optional translucent backdrop drawn behind every colored token.
    /// `nil` means no per-token background (the natural editor
    /// background shows through). Used by the overlay layout to keep
    /// tokens legible against the live shader render.
    public var tokenBackground: Color?

    public init(
        foreground: Color,
        comment: Color,
        identifier: Color,
        number: Color,
        type: Color,
        keyword: Color,
        callExpression: Color,
        tomlKey: Color,
        tomlString: Color,
        tomlNumber: Color,
        tomlBoolean: Color,
        tomlTableHeader: Color,
        tokenBackground: Color? = nil
    ) {
        self.foreground = foreground
        self.comment = comment
        self.identifier = identifier
        self.number = number
        self.type = type
        self.keyword = keyword
        self.callExpression = callExpression
        self.tomlKey = tomlKey
        self.tomlString = tomlString
        self.tomlNumber = tomlNumber
        self.tomlBoolean = tomlBoolean
        self.tomlTableHeader = tomlTableHeader
        self.tokenBackground = tokenBackground
    }

    /// Default palette used on the side-by-side editor pane (text on a
    /// system text-background color).
    public static let `default` = SyntaxPalette(
        foreground: .primary,
        comment: .green,
        identifier: .blue,
        number: .orange,
        type: .purple,
        keyword: .pink,
        callExpression: .teal,
        tomlKey: .blue,
        tomlString: .red,
        tomlNumber: .orange,
        tomlBoolean: .pink,
        tomlTableHeader: .purple
    )

    /// Dark-mode palette: light, slightly desaturated colors that read
    /// well against a dark editor background.
    public static let dark = SyntaxPalette(
        foreground: Color(white: 0.85),
        comment: Color(red: 0.45, green: 0.7, blue: 0.45),
        identifier: Color(red: 0.55, green: 0.8, blue: 1.0),
        number: Color(red: 1.0, green: 0.75, blue: 0.4),
        type: Color(red: 0.85, green: 0.6, blue: 1.0),
        keyword: Color(red: 1.0, green: 0.5, blue: 0.7),
        callExpression: Color(red: 0.5, green: 0.95, blue: 0.95),
        tomlKey: Color(red: 0.55, green: 0.8, blue: 1.0),
        tomlString: Color(red: 1.0, green: 0.7, blue: 0.55),
        tomlNumber: Color(red: 1.0, green: 0.75, blue: 0.4),
        tomlBoolean: Color(red: 1.0, green: 0.5, blue: 0.7),
        tomlTableHeader: Color(red: 0.85, green: 0.6, blue: 1.0)
    )

    /// Same as ``dark`` but with a translucent dark backdrop behind every
    /// line of code. Used by the overlay layout so tokens stay legible
    /// against the live shader render.
    public static let darkWithBackdrop = SyntaxPalette(
        foreground: Color(white: 0.85),
        comment: Color(red: 0.45, green: 0.7, blue: 0.45),
        identifier: Color(red: 0.55, green: 0.8, blue: 1.0),
        number: Color(red: 1.0, green: 0.75, blue: 0.4),
        type: Color(red: 0.85, green: 0.6, blue: 1.0),
        keyword: Color(red: 1.0, green: 0.5, blue: 0.7),
        callExpression: Color(red: 0.5, green: 0.95, blue: 0.95),
        tomlKey: Color(red: 0.55, green: 0.8, blue: 1.0),
        tomlString: Color(red: 1.0, green: 0.7, blue: 0.55),
        tomlNumber: Color(red: 1.0, green: 0.75, blue: 0.4),
        tomlBoolean: Color(red: 1.0, green: 0.5, blue: 0.7),
        tomlTableHeader: Color(red: 0.85, green: 0.6, blue: 1.0),
        tokenBackground: Color.black.opacity(0.6)
    )
}
