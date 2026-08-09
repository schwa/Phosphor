/// A semantic category a highlighter can assign to a run of source text.
///
/// Roles are deliberately language-neutral: a ``SourceLanguage`` maps its own
/// grammar node names onto them, and a ``SyntaxPalette`` maps them onto colors.
/// The built-in cases cover the common ones; callers with a language that needs
/// something else can mint their own role and add it to their palette.
public struct TokenRole: Hashable, Sendable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let comment = Self(rawValue: "comment")
    public static let identifier = Self(rawValue: "identifier")
    public static let number = Self(rawValue: "number")
    public static let type = Self(rawValue: "type")
    public static let keyword = Self(rawValue: "keyword")
    public static let call = Self(rawValue: "call")
    public static let string = Self(rawValue: "string")
    public static let boolean = Self(rawValue: "boolean")
    /// A key in a key/value language (TOML, YAML, JSON).
    public static let key = Self(rawValue: "key")
    /// A section or table header.
    public static let heading = Self(rawValue: "heading")
}

extension TokenRole: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
