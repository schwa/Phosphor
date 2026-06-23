import Foundation
import PhosphorModel
@testable import PhosphorCompile
import Testing

@Suite("PhosphorHeader")
struct PhosphorHeaderTests {
    @Test("Per-pass Textures struct emits one field per binding")
    func perPassTexturesStruct() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        let header = PhosphorHeader.source(for: config)
        #expect(header.contains("struct Pass_image_Textures {"))
        #expect(header.contains("texture2d<float, access::write> image;"))
    }

    @Test("Per-pass Uniforms struct carries scalars + nested Textures")
    func perPassUniformsStruct() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        let header = PhosphorHeader.source(for: config)
        #expect(header.contains("struct Pass_image_Uniforms {"))
        #expect(header.contains("Pass_image_Textures textures;"))
    }

    @Test("Different access modes per binding")
    func accessModes() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "img"), Texture(id: "src")],
            passes: [
                Pass(id: "p", textures: [
                    .init(id: "img", access: .write),
                    .init(id: "src", access: .sample)
                ])
            ],
            output: "img"
        )
        let header = PhosphorHeader.source(for: config)
        #expect(header.contains("texture2d<float, access::write> img;"))
        #expect(header.contains("texture2d<float, access::sample> src;"))
    }

    @Test("UserUniforms reflects declared uniforms")
    func userUniformsStruct() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [Pass(id: "image", textures: [.init(id: "image", access: .write)])],
            output: "image",
            uniforms: [
                .init(name: "intensity", kind: .float, defaultValue: .float(1)),
                .init(name: "tint", kind: .float3, defaultValue: .float3(.init(1, 0.5, 0.2))),
                .init(name: "enabled", kind: .bool, defaultValue: .bool(true))
            ]
        )
        let header = PhosphorHeader.source(for: config)
        #expect(header.contains("float intensity;"))
        #expect(header.contains("float3 tint;"))
        #expect(header.contains("bool enabled;"))
    }

    @Test("Empty UserUniforms still compiles by including a placeholder field")
    func emptyUserUniforms() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [Pass(id: "image", textures: [.init(id: "image", access: .write)])],
            output: "image"
        )
        let header = PhosphorHeader.source(for: config)
        #expect(header.contains("struct UserUniforms {\n    int _unused;\n};"))
    }
}

@Suite("SourceAssembler")
struct SourceAssemblerTests {
    @Test("Strips '#include \"Phosphor.h\"'")
    func stripsInclude() {
        let source = """
        #include "Phosphor.h"

        kernel void image(...) {}
        """
        let cleaned = SourceAssembler.stripPhosphorHeaderInclude(source)
        #expect(!cleaned.contains("Phosphor.h"))
    }

    @Test("Tolerates whitespace before '#include'")
    func stripsIndentedInclude() {
        let source = "   #include \"Phosphor.h\"\nbody"
        let cleaned = SourceAssembler.stripPhosphorHeaderInclude(source)
        #expect(!cleaned.contains("Phosphor.h"))
    }

    @Test("Strips front-matter block at top of file")
    func stripsFrontMatter() {
        let source = """
        /* phosphor:environment
        output = "image"
        */

        kernel void image(...) {}
        """
        let cleaned = SourceAssembler.stripFrontMatter(source)
        #expect(!cleaned.contains("phosphor:environment"))
        #expect(cleaned.contains("kernel void image"))
    }

    @Test("Doesn't strip a stray '/* phosphor:environment */' deep in the source")
    func leavesEmbeddedCommentsAlone() {
        let source = """
        kernel void image(...) {
            /* phosphor:environment is not at the top */
        }
        """
        let cleaned = SourceAssembler.stripFrontMatter(source)
        #expect(cleaned == source)
    }

    @Test("Injects #define Uniforms / Textures before each pass's kernel")
    func injectsPassDefines() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        let body = """
        kernel void image() {}
        """
        let injected = SourceAssembler.injectPassDefines(into: body, config: config)
        #expect(injected.contains("#define Uniforms Pass_image_Uniforms"))
        #expect(injected.contains("#define Textures Pass_image_Textures"))
    }
}
