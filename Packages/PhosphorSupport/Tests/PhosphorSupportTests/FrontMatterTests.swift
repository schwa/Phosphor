import Foundation
@testable import PhosphorSupport
import Testing

@Suite("FrontMatter")
struct FrontMatterTests {
    @Test("No front-matter yields nil environment, original body, no diagnostics")
    func noFrontMatter() {
        let source = "kernel void image(...) {}"
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.environment == nil)
        #expect(result.body == source)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Single-pass front-matter parses to expected environment")
    func singlePass() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[resources]]
        kind = "texture2D"
        id = "image"
        spec = { size = "drawable", format = "rgba32Float", pingPong = true, flipTiming = "endOfFrame", initial = "zero" }

        [[passes]]
        id = "image"
        output = "image"
        inputs = [{ name = "iChannel0", resource = "image" }]
        */

        kernel void image(...) {}
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let env = try #require(result.environment)
        #expect(env.output == "image")
        #expect(env.resources.count == 1)
        if case let .texture2D(id, spec) = env.resources[0] {
            #expect(id == "image")
            #expect(spec.size == .drawable)
            #expect(spec.format == .rgba32Float)
            #expect(spec.pingPong == true)
            #expect(spec.flipTiming == .endOfFrame)
            #expect(spec.initial == .zero)
        } else {
            Issue.record("expected texture2D resource")
        }
        #expect(env.passes.count == 1)
        #expect(env.passes[0].id == "image")
        #expect(env.passes[0].output == "image")
        #expect(env.passes[0].inputs == [Pass.Input(name: "iChannel0", resource: "image")])

        // Body is the post-front-matter content.
        #expect(result.body.contains("kernel void image"))
        #expect(!result.body.contains("phosphor:environment"))
    }

    @Test("Phosphor2.md §4 example parses end-to-end")
    func designDocExample() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[resources]]
        kind = "texture2D"
        id = "bufA"
        spec = { size = "drawable", format = "rgba16Float", pingPong = true, flipTiming = "endOfFrame", initial = "zero" }

        [[resources]]
        kind = "texture2D"
        id = "image"
        spec = { size = "drawable", format = "rgba16Float", pingPong = false, initial = "zero" }

        [[passes]]
        id = "bufA"
        output = "bufA"
        inputs = [
            { name = "iChannel0", resource = "bufA" },
        ]

        [[passes]]
        id = "image"
        output = "image"
        inputs = [
            { name = "iChannel0", resource = "bufA" },
        ]

        [[uniforms]]
        name = "intensity"
        kind = "float"
        default = 1.0
        ui = { slider = { min = 0.0, max = 4.0 } }
        */

        kernel void bufA(...) {}
        kernel void image(...) {}
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let env = try #require(result.environment)

        // Resources
        #expect(env.resources.count == 2)

        // Passes
        #expect(env.passes.count == 2)
        #expect(env.passes.map(\.id) == ["bufA", "image"])

        // Uniforms
        #expect(env.uniforms.count == 1)
        let uniform = env.uniforms[0]
        #expect(uniform.name == "intensity")
        #expect(uniform.kind == .float)
        #expect(uniform.defaultValue == .float(1.0))
        #expect(uniform.ui == .slider(min: 0.0, max: 4.0))
    }

    @Test("TOML syntax error surfaces as frontMatterParse diagnostic")
    func badTOML() {
        let source = """
        /* phosphor:environment
        output = "image
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.environment == nil)
        #expect(result.diagnostics.contains { diagnostic in
            if case .frontMatterParse = diagnostic { return true }
            return false
        })
    }

    @Test("Validation errors propagate through parse")
    func validationError() {
        // 'output' references a resource that doesn't exist.
        let source = """
        /* phosphor:environment
        output = "missing"

        [[resources]]
        kind = "texture2D"
        id = "image"
        spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

        [[passes]]
        id = "image"
        output = "image"
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        // Environment is still constructed; validation diagnostics come back alongside.
        #expect(result.environment != nil)
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
        #expect(result.environment == nil)
        #expect(result.body == source)
    }

    @Test("Leading line comments and block comments before front-matter are skipped")
    func leadingCommentsAreSkipped() {
        let source = """
        // generated by Apple Intelligence
        /* prompt: a swirling galaxy */

        /* phosphor:environment
        output = "image"

        [[resources]]
        kind = "texture2D"
        id = "image"
        spec = { size = "drawable", format = "rgba32Float" }

        [[passes]]
        id = "image"
        output = "image"
        */

        kernel void image(...) {}
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        #expect(result.environment != nil)
        #expect(result.body.contains("kernel void image"))
    }

    @Test("Inline non-pingpong spec round-trips without flipTiming field")
    func inlineSpecRoundTrip() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[resources]]
        kind = "texture2D"
        id = "image"
        spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

        [[passes]]
        id = "image"
        output = "image"
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let env = try #require(result.environment)
        if case let .texture2D(_, spec) = env.resources[0] {
            #expect(spec.pingPong == false)
            #expect(spec.flipTiming == .endOfFrame)
        }
    }
}
