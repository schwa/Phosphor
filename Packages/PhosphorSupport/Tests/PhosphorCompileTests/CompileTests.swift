import Foundation
import PhosphorModel
@testable import PhosphorCompile
import Metal
import Testing

@Suite("Compile against MTLDevice")
struct CompileTests {
    /// Headless trivial kernel exercising the new Texture model:
    /// one output binding (access = .write), one pass.
    @Test("Trivial single-pass kernel compiles into a live MTLLibrary")
    func trivialSinglePass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        let source = """
        #include "Phosphor.h"

        uint2 gid [[thread_position_in_grid]];

        kernel void image(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            float2 uv = float2(gid) / uniforms.resolution;
            uniforms.textures.image.write(float4(uv, sin(uniforms.time), 1), gid);
        }
        """
        let compiler = PhosphorCompiler(device: device)
        let library = try compiler.compileLibrary(configuration: config, userSource: source)
        let function = try compiler.makeFunction(library: library, for: "image")
        #expect(function.name == "image")
    }

    @Test("Multi-pass kernels with shared textures + user uniforms compile")
    func multiPass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }
        let config = PhosphorConfiguration(
            textures: [
                Texture(id: "bufA", swap: .endOfFrame),
                Texture(id: "image")
            ],
            passes: [
                Pass(id: "bufA", textures: [
                    .init(id: "bufA", access: .write),
                    .init(id: "bufA", access: .read, name: "feedback")
                ]),
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "bufA", access: .read)
                ])
            ],
            output: "image",
            uniforms: [
                .init(name: "intensity", kind: .float, defaultValue: .float(1.0))
            ]
        )
        let source = """
        #include "Phosphor.h"

        uint2 gid [[thread_position_in_grid]];

        kernel void bufA(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            float4 prev = uniforms.textures.feedback.read(gid);
            uniforms.textures.bufA.write(prev * 0.95 * userUniforms.intensity, gid);
        }

        kernel void image(
            device const Uniforms&     uniforms     [[buffer(0)]],
            device const UserUniforms& userUniforms [[buffer(1)]])
        {
            uniforms.textures.image.write(uniforms.textures.bufA.read(gid), gid);
        }
        """
        let compiler = PhosphorCompiler(device: device)
        let library = try compiler.compileLibrary(configuration: config, userSource: source)
        _ = try compiler.makeFunction(library: library, for: "bufA")
        _ = try compiler.makeFunction(library: library, for: "image")
    }

    @Test("BuiltinUniforms size matches MSL struct prefix (sanity)")
    func uniformsLayout() {
        // 3 × float (12) + float2 (8) + float2 (8) + uint (4) + uint (4)
        // + float2 (8) + 2 × ulong (16) = 60, padded to 8 = 64.
        // Actually: 3*4 + 8 + 8 + 4 + 4 + 8 + 8 + 8 = 60 bytes, stride 64.
        #expect(MemoryLayout<BuiltinUniforms>.size >= 60)
    }
}
