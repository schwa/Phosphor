import Foundation
import Testing
@testable import PhosphorSupport

@Suite("PhosphorHeader")
struct PhosphorHeaderTests {
    @Test("Zero channels emits an empty ChannelBindings struct")
    func zeroChannels() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init())],
            passes: [Pass(id: "image", output: "image")],
            output: "image"
        )
        let header = PhosphorHeader.source(for: env)
        #expect(header.contains("struct ChannelBindings {\n};"))
    }

    @Test("ChannelBindings struct contains N iChannel slots")
    func channelSlots() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel2", resource: "image")],
                    output: "image"
                ),
            ],
            output: "image"
        )
        let header = PhosphorHeader.source(for: env)
        #expect(header.contains("texture2d<float, access::read> iChannel0;"))
        #expect(header.contains("texture2d<float, access::read> iChannel1;"))
        #expect(header.contains("texture2d<float, access::read> iChannel2;"))
        #expect(!header.contains("iChannel3;"))
    }

    @Test("UserUniforms reflects declared uniforms")
    func userUniformsStruct() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init())],
            passes: [Pass(id: "image", output: "image")],
            output: "image",
            uniforms: [
                .init(name: "intensity", kind: .float, defaultValue: .float(1)),
                .init(name: "tint", kind: .float3, defaultValue: .float3(.init(1, 0.5, 0.2))),
                .init(name: "enabled", kind: .bool, defaultValue: .bool(true)),
            ]
        )
        let header = PhosphorHeader.source(for: env)
        #expect(header.contains("float intensity;"))
        #expect(header.contains("float3 tint;"))
        #expect(header.contains("bool enabled;"))
    }

    @Test("Empty UserUniforms still compiles by including a placeholder field")
    func emptyUserUniforms() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init())],
            passes: [Pass(id: "image", output: "image")],
            output: "image"
        )
        let header = PhosphorHeader.source(for: env)
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
}
