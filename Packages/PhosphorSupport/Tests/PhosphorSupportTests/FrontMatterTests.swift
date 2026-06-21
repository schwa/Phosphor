import Foundation
@testable import PhosphorSupport
import Testing

@Suite("FrontMatter")
struct FrontMatterTests {
    @Test("No front-matter yields nil configuration, original body, no diagnostics")
    func noFrontMatter() {
        let source = "kernel void image(...) {}"
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.configuration == nil)
        #expect(result.body == source)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Single-pass front-matter parses to expected configuration")
    func singlePass() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "image"
        size = "drawable"
        format = "rgba32Float"
        swap = "endOfFrame"
        init = { kind = "zero" }

        [[passes]]
        id = "image"
        textures = [
            { id = "image", access = "write" },
            { id = "image", access = "read", name = "feedback" },
        ]
        */

        kernel void image(...) {}
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let config = try #require(result.configuration)
        #expect(config.output == "image")
        #expect(config.textures.count == 1)

        let texture = config.textures[0]
        #expect(texture.id == "image")
        #expect(texture.size == .drawable)
        #expect(texture.format == .rgba32Float)
        #expect(texture.swap == .endOfFrame)
        #expect(texture.initialContents == .zero)

        #expect(config.passes.count == 1)
        #expect(config.passes[0].id == "image")
        #expect(config.passes[0].textures == [
            Pass.TextureBinding(id: "image", access: .write),
            Pass.TextureBinding(id: "image", access: .read, name: "feedback")
        ])

        #expect(result.body.contains("kernel void image"))
        #expect(!result.body.contains("phosphor:environment"))
    }

    @Test("Texture defaults: omitted fields fall back to canonical values")
    func textureDefaults() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let config = try #require(result.configuration)
        let texture = config.textures[0]
        #expect(texture.size == .drawable)
        #expect(texture.format == .rgba32Float)
        #expect(texture.swap == .none)
        #expect(texture.initialContents == .zero)
    }

    @Test("Image-init texture decodes name field")
    func imageInit() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "photo"
        init = { kind = "image", file = "screenshot.png" }

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [
            { id = "image", access = "write" },
            { id = "photo", access = "sample" },
        ]
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let config = try #require(result.configuration)
        let photo = config.textures.first { $0.id == "photo" }!
        #expect(photo.initialContents == .image(file: "screenshot.png"))
    }

    @Test("TOML syntax error surfaces as frontMatterParse diagnostic")
    func badTOML() {
        let source = """
        /* phosphor:environment
        output = "image
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.configuration == nil)
        #expect(result.diagnostics.contains { diagnostic in
            if case .frontMatterParse = diagnostic { return true }
            return false
        })
    }

    @Test("Validation errors propagate through parse")
    func validationError() {
        // 'output' references a texture that doesn't exist.
        let source = """
        /* phosphor:environment
        output = "missing"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.configuration != nil)
        #expect(result.diagnostics.contains(.missingOutput("missing")))
    }

    @Test("Front-matter must be at top — embedded /* phosphor:environment */ is ignored")
    func mustBeAtTop() {
        let source = """
        kernel void image(...) {
            /* phosphor:environment is not at the top
            output = "image"
            */
        }
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.configuration == nil)
        #expect(result.body == source)
    }

    @Test("Leading line comments and block comments before front-matter are skipped")
    func leadingCommentsAreSkipped() {
        let source = """
        // generated by Apple Intelligence
        /* prompt: a swirling galaxy */

        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [{ id = "image", access = "write" }]
        */

        kernel void image(...) {}
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        #expect(result.configuration != nil)
        #expect(result.body.contains("kernel void image"))
    }
}
