import SwiftUI

/// Color palette for ``MetalSourceView`` syntax highlighting.
///
/// Holds one ``Color`` per token category. Cover both Metal (C++) and
/// the front-matter TOML; categories that don't apply on one side are
/// simply ignored by that side's walker.
public struct SyntaxPalette: Hashable, Sendable {
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

    /// Same as ``default`` but with a translucent dark backdrop behind
    /// every colored token. Used by the overlay layout so tokens stay
    /// legible against the live shader render.
    public static let withBackdrop = SyntaxPalette(
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
        tomlTableHeader: .purple,
        tokenBackground: Color.black.opacity(0.6)
    )
}
