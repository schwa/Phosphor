import SwiftTreeSitter

/// A tree-sitter grammar plus the mapping from its node types to
/// ``TokenRole`` values, and any sub-languages embedded in the text.
///
/// The editor target ships no grammars of its own; callers supply them. A
/// minimal language is a grammar and a node-type table:
///
/// ```swift
/// let json = SourceLanguage(
///     id: "json",
///     language: Language(tree_sitter_json()),
///     roles: ["string": .string, "number": .number]
/// )
/// ```
public struct SourceLanguage: Sendable, Identifiable {
    /// Stable identity, used to invalidate cached highlighting.
    public let id: String
    public let language: Language
    /// Grammar node type (`node.nodeType`) to semantic role.
    public let roles: [String: TokenRole]
    /// Locates sub-ranges written in another language — front-matter, embedded
    /// scripts, heredocs. Each region is re-highlighted with its own language
    /// after the outer pass, so it wins on overlap.
    public let embeddedRegions: @Sendable (String) -> [EmbeddedRegion]

    @preconcurrency
    public init(
        id: String,
        language: Language,
        roles: [String: TokenRole],
        embeddedRegions: @escaping @Sendable (String) -> [EmbeddedRegion] = { _ in [] }
    ) {
        self.id = id
        self.language = language
        self.roles = roles
        self.embeddedRegions = embeddedRegions
    }
}

/// A span of source written in a different language than its surroundings.
public struct EmbeddedRegion: Sendable {
    public var range: Range<String.Index>
    public var language: SourceLanguage

    public init(range: Range<String.Index>, language: SourceLanguage) {
        self.range = range
        self.language = language
    }
}
