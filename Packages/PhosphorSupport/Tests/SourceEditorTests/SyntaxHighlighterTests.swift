import PhosphorEditorSupport
import SourceEditor
import SwiftUI
import Testing

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    /// Distinct colors per role so a test can tell them apart by inspection.
    static let palette = SyntaxPalette(
        foreground: .white,
        styles: [
            .comment: TokenStyle(.green),
            .number: TokenStyle(.orange),
            .type: TokenStyle(.purple),
            .key: TokenStyle(.blue),
            .string: TokenStyle(.red)
        ]
    )

    /// Returns the color applied to the first occurrence of `substring`.
    private func color(of substring: String, in source: String, language: SourceLanguage) throws -> Color? {
        let attributed = try SyntaxHighlighter.highlight(source, language: language, palette: Self.palette)
        let plain = String(attributed.characters)
        let target = try #require(plain.range(of: substring))
        let offset = plain.utf16.distance(from: plain.startIndex, to: target.lowerBound)
        let index = try #require(
            AttributedString.Index(
                plain.utf16.index(plain.utf16.startIndex, offsetBy: offset),
                within: attributed
            )
        )
        return attributed[index...].runs.first?.foregroundColor
    }

    @Test("Maps grammar nodes onto palette colors")
    func colorsTokensByRole() throws {
        let source = "// note\nfloat v = 42;\n"
        #expect(try color(of: "// note", in: source, language: .metal) == .green)
        #expect(try color(of: "float", in: source, language: .metal) == .purple)
        #expect(try color(of: "42", in: source, language: .metal) == .orange)
    }

    @Test("Unclassified characters fall back to the palette foreground")
    func fallsBackToForeground() throws {
        #expect(try color(of: ";", in: "float v = 42;\n", language: .metal) == .white)
    }

    /// The front-matter block is C++ comment syntax on the outside and TOML on
    /// the inside; the embedded pass has to win over the comment coloring.
    @Test("Embedded regions are highlighted with their own language")
    func embeddedRegionOverridesOuterLanguage() throws {
        let source = """
        /* phosphor:environment
        output = "image"
        */
        kernel void image() {}
        """
        #expect(try color(of: "output", in: source, language: .metal) == .blue)
        #expect(try color(of: "\"image\"", in: source, language: .metal) == .red)
    }

    @Test("A language with no embedded regions leaves the whole text to the outer grammar")
    func plainTOMLHighlights() throws {
        #expect(try color(of: "size", in: "size = 4\n", language: .toml) == .blue)
        #expect(try color(of: "4", in: "size = 4\n", language: .toml) == .orange)
    }
}
