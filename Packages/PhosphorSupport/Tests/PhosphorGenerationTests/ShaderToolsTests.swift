import CollaborationKit
import Foundation
import PhosphorCompile
@testable import PhosphorGeneration
import PhosphorModel
import Testing

/// A source with a front-matter block and a simple kernel body, for exercising
/// the body/front-matter split the tools rely on.
private let sampleSource = """
/* phosphor:environment
output = "image"

[[passes]]
id = "image"
textures = [{ id = "image", access = "write" }]
*/

kernel void image() {
    textures.image.write(float4(1.0, 0.0, 0.0, 1.0), gid);
}
"""

private func makeDocument(_ source: String = sampleSource) -> MetalSourceDocument {
    MetalSourceDocument(inMemory: source)
}

// MARK: - editMetal

@Suite("EditMetalTool")
struct EditMetalToolTests {
    @Test("applies a unique edit to the body")
    func appliesUniqueEdit() async throws {
        let doc = makeDocument()
        let tool = EditMetalTool(document: doc)
        let result = try await tool.call(.init(oldText: "float4(1.0, 0.0, 0.0, 1.0)", newText: "float4(0.0, 1.0, 0.0, 1.0)"))
        #expect(result == "Edit applied.")
        let updated = try doc.read()
        #expect(updated.contains("float4(0.0, 1.0, 0.0, 1.0)"))
        // Front-matter is untouched.
        #expect(updated.contains("/* phosphor:environment"))
        #expect(updated.contains("output = \"image\""))
    }

    @Test("rejects text not found in the body")
    func rejectsNotFound() async throws {
        let doc = makeDocument()
        let tool = EditMetalTool(document: doc)
        await #expect(throws: ToolError.self) {
            try await tool.call(.init(oldText: "nonexistent token", newText: "x"))
        }
    }

    @Test("rejects non-unique text")
    func rejectsNonUnique() async throws {
        let doc = makeDocument("/* phosphor:environment\noutput = \"image\"\n*/\nkernel void image() { float a; float a2; }")
        let tool = EditMetalTool(document: doc)
        await #expect(throws: ToolError.self) {
            try await tool.call(.init(oldText: "float ", newText: "half "))
        }
    }

    @Test("does not match text inside the front-matter")
    func ignoresFrontMatter() async throws {
        let doc = makeDocument()
        let tool = EditMetalTool(document: doc)
        // "output" only appears in the front-matter; editing the body must not find it.
        await #expect(throws: ToolError.self) {
            try await tool.call(.init(oldText: "output = \"image\"", newText: "output = \"other\""))
        }
    }
}

// MARK: - readConfiguration

@Suite("ReadConfigurationTool")
struct ReadConfigurationToolTests {
    @Test("returns the parsed configuration as JSON")
    func returnsJSON() async throws {
        let doc = makeDocument()
        let tool = ReadConfigurationTool(document: doc)
        let json = try await tool.call(.init())
        #expect(json.contains("\"output\""))
        #expect(json.contains("image"))
        // It's valid JSON decoding back into a configuration.
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(PhosphorConfiguration.self, from: data)
        #expect(config.output == "image")
    }
}

// MARK: - writeConfiguration

@Suite("WriteConfigurationTool")
struct WriteConfigurationToolTests {
    @Test("rewrites the front-matter and preserves the body")
    func rewritesFrontMatter() async throws {
        let doc = makeDocument()
        let tool = WriteConfigurationTool(document: doc)
        let dto = try decodeDTO("""
        { "configuration": { "output": "image",
          "resources": [{ "id": "image", "format": "rgba16Float" }],
          "passes": [{ "id": "image", "output": "image" }] } }
        """)
        let result = try await tool.call(dto)
        #expect(result.hasPrefix("Configuration written"))

        let updated = try doc.read()
        // Body preserved.
        #expect(updated.contains("kernel void image()"))
        // New format landed in the re-emitted front-matter.
        let parsed = ParsedPhosphorSource(source: updated)
        #expect(parsed.configuration.texture("image")?.format == .rgba16Float)
    }

    @Test("rejects an invalid configuration")
    func rejectsInvalid() async throws {
        let doc = makeDocument()
        let tool = WriteConfigurationTool(document: doc)
        // output references a resource/pass that doesn't exist → fatal validation.
        let dto = try decodeDTO("""
        { "configuration": { "output": "missing", "resources": [], "passes": [] } }
        """)
        await #expect(throws: ToolError.self) {
            try await tool.call(dto)
        }
    }

    private func decodeDTO(_ json: String) throws -> WriteConfigurationTool.Input {
        try JSONDecoder().decode(WriteConfigurationTool.Input.self, from: Data(json.utf8))
    }
}

// MARK: - compileShader

@Suite("CompileShaderTool")
struct CompileShaderToolTests {
    @Test("reports clean compile")
    func reportsClean() async throws {
        let doc = makeDocument()
        let tool = CompileShaderTool(document: doc) { _ in nil }
        let result = try await tool.call(.init())
        #expect(result == "Compiles cleanly.")
    }

    @Test("reports compile errors")
    func reportsErrors() async throws {
        let doc = makeDocument()
        let tool = CompileShaderTool(document: doc) { _ in "error: use of undeclared identifier 'foo'" }
        let result = try await tool.call(.init())
        #expect(result.contains("Compile failed"))
        #expect(result.contains("undeclared identifier"))
    }

    @Test("compile check sees the live document edits")
    func seesLiveEdits() async throws {
        let doc = makeDocument()
        // The check reports the current body length, proving it reads live state.
        let tool = CompileShaderTool(document: doc) { parsed in
            parsed.body.contains("green") ? nil : "not green yet"
        }
        #expect(try await tool.call(.init()).contains("not green yet"))
        try doc.write(sampleSource + "\n// green")
        #expect(try await tool.call(.init()) == "Compiles cleanly.")
    }
}

// MARK: - ConfigurationDTO mapping

@Suite("ConfigurationDTO")
struct ConfigurationDTOTests {
    @Test("maps flat resources/passes to runtime bindings")
    func mapsToRuntime() throws {
        let json = """
        { "output": "image",
          "resources": [
            { "id": "bufA", "pingPong": true },
            { "id": "image" }
          ],
          "passes": [
            { "id": "bufA", "output": "bufA", "inputs": [{ "name": "iChannel0", "resource": "bufA" }] },
            { "id": "image", "output": "image", "inputs": [{ "name": "iChannel0", "resource": "bufA" }] }
          ],
          "uniforms": [
            { "name": "speed", "kind": "float", "defaultValue": [1.0], "sliderMin": 0.0, "sliderMax": 5.0 }
          ] }
        """
        let dto = try JSONDecoder().decode(ConfigurationDTO.self, from: Data(json.utf8))
        let config = dto.toConfiguration()

        #expect(config.output == "image")
        #expect(config.textures.count == 2)
        #expect(config.texture("bufA")?.swap == .endOfFrame)

        // Self-feedback pass gets a write binding plus a distinct `bufAPrev` read.
        let bufA = try #require(config.passes.first { $0.id == "bufA" })
        #expect(bufA.textures.contains { $0.access == .write && $0.id == "bufA" })
        #expect(bufA.textures.contains { $0.access == .read && $0.name == "bufAPrev" })

        // Uniform maps to a slider.
        let speed = try #require(config.uniforms.first { $0.name == "speed" })
        if case .slider(let lo, let hi) = speed.ui {
            #expect(lo == 0.0)
            #expect(hi == 5.0)
        } else {
            Issue.record("expected a slider UI hint")
        }
    }
}
