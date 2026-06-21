import Foundation
import Metal
@testable import PhosphorSupport
import Testing

@Suite("ShaderCompiler")
struct ShaderCompilerTests {
    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }
        return device
    }

    private let cleanSource = """
    #include "Phosphor.h"

    uint2 gid [[thread_position_in_grid]];

    kernel void image(
        device const Uniforms&     uniforms     [[buffer(0)]],
        device const UserUniforms& userUniforms [[buffer(1)]])
    {
        float2 uv = float2(gid) / uniforms.resolution;
        uniforms.textures.image.write(float4(uv, 0, 1), gid);
    }
    """

    private func singlePassConfig() -> PhosphorConfiguration {
        PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [Pass(id: "image", textures: [.init(id: "image", access: .write)])],
            output: "image"
        )
    }

    @Test("Clean source yields a renderable library with all pass functions")
    func cleanCompile() throws {
        let device = try device()
        let result = ShaderCompiler.compile(
            configuration: singlePassConfig(),
            userSource: cleanSource,
            device: device
        )
        #expect(result.library != nil)
        #expect(result.passFunctions["image"] != nil)
        #expect(result.isRenderable)
        #expect(result.firstCompileError == nil)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Metal syntax error surfaces as a compile diagnostic, no library")
    func badMetalSource() throws {
        let device = try device()
        let broken = """
        #include "Phosphor.h"

        kernel void image(
            device const Uniforms& uniforms [[buffer(0)]])
        {
            this is not valid metal;
        }
        """
        let result = ShaderCompiler.compile(
            configuration: singlePassConfig(),
            userSource: broken,
            device: device
        )
        #expect(result.library == nil)
        #expect(result.passFunctions.isEmpty)
        #expect(!result.isRenderable)
        #expect(result.firstCompileError != nil)
        #expect(result.diagnostics.contains { if case .compile = $0 { return true } else { return false } })
    }

    @Test("Fatal validation error short-circuits before touching Metal")
    func fatalValidation() throws {
        let device = try device()
        // output refers to a texture that doesn't exist → fatal validation.
        let config = PhosphorConfiguration(output: "image")
        let result = ShaderCompiler.compile(
            configuration: config,
            userSource: cleanSource,
            device: device
        )
        #expect(result.library == nil)
        #expect(result.passFunctions.isEmpty)
        #expect(!result.isRenderable)
        #expect(result.diagnostics.contains(.missingOutput("image")))
    }

    @Test("Existing diagnostics are carried through")
    func existingDiagnosticsPreserved() throws {
        let device = try device()
        let front: [PhosphorDiagnostic] = [.missingAsset(name: "tex.png", in: "image")]
        let result = ShaderCompiler.compile(
            configuration: singlePassConfig(),
            userSource: cleanSource,
            device: device,
            existingDiagnostics: front
        )
        // Non-fatal asset diagnostic preserved; library still compiles.
        #expect(result.library != nil)
        #expect(result.diagnostics.contains(.missingAsset(name: "tex.png", in: "image")))
    }
}
