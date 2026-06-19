import Foundation
import Metal
@testable import PhosphorSupport
import Testing

@Suite("Compile against MTLDevice")
struct CompileTests {
    /// Headless trivial kernel: writes a constant color to the output texture.
    /// Exercises Uniforms, ChannelBindings, UserUniforms (all empty), and the
    /// canonical kernel signature.
    @Test("Trivial single-pass kernel compiles into a live MTLLibrary")
    func trivialSinglePass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [Pass(id: "image", output: "image")],
            output: "image"
        )
        let source = """
        #include "Phosphor.h"

        kernel void image(
            texture2d<float, access::write> outTexture     [[texture(0)]],
            device const ChannelBindings&   channels       [[buffer(1)]],
            device const Uniforms*          uniforms       [[buffer(0)]],
            device const UserUniforms*      userUniforms   [[buffer(2)]],
            uint2 gid                                      [[thread_position_in_grid]])
        {
            float2 uv = float2(gid) / uniforms->resolution;
            outTexture.write(float4(uv, sin(uniforms->time), 1), gid);
        }
        """
        let compiler = PhosphorCompiler(device: device)
        let library = try compiler.compileLibrary(environment: env, userSource: source)
        let function = try compiler.makeFunction(library: library, for: "image")
        #expect(function.name == "image")
    }

    @Test("Multi-pass kernels with channels + user uniforms compile")
    func multiPass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }
        let env = PhosphorEnvironment(
            resources: [
                .texture2D(id: "bufA", spec: .init(pingPong: true)),
                .texture2D(id: "image", spec: .init(pingPong: false))
            ],
            passes: [
                Pass(
                    id: "bufA",
                    inputs: [.init(name: "iChannel0", resource: "bufA")],
                    output: "bufA"
                ),
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel0", resource: "bufA")],
                    output: "image"
                )
            ],
            output: "image",
            uniforms: [
                .init(name: "intensity", kind: .float, defaultValue: .float(1.0))
            ]
        )
        let source = """
        #include "Phosphor.h"

        kernel void bufA(
            texture2d<float, access::write> outTexture     [[texture(0)]],
            device const ChannelBindings&   channels       [[buffer(1)]],
            device const Uniforms*          uniforms       [[buffer(0)]],
            device const UserUniforms*      userUniforms   [[buffer(2)]],
            uint2 gid                                      [[thread_position_in_grid]])
        {
            float4 prev = channels.iChannel0.read(gid);
            outTexture.write(prev * 0.95 * userUniforms->intensity, gid);
        }

        kernel void image(
            texture2d<float, access::write> outTexture     [[texture(0)]],
            device const ChannelBindings&   channels       [[buffer(1)]],
            device const Uniforms*          uniforms       [[buffer(0)]],
            device const UserUniforms*      userUniforms   [[buffer(2)]],
            uint2 gid                                      [[thread_position_in_grid]])
        {
            outTexture.write(channels.iChannel0.read(gid), gid);
        }
        """
        let compiler = PhosphorCompiler(device: device)
        let library = try compiler.compileLibrary(environment: env, userSource: source)
        _ = try compiler.makeFunction(library: library, for: "bufA")
        _ = try compiler.makeFunction(library: library, for: "image")
    }

    @Test("BuiltinUniforms size matches MSL struct (sanity)")
    func uniformsLayout() {
        // float, float, float, uint, float2, float2, uint, uint, float2, ulong, ulong
        // = 4 + 4 + 4 + 4 + 8 + 8 + 4 + 4 + 8 + 8 + 8 = 64 bytes
        #expect(MemoryLayout<BuiltinUniforms>.size == 64)
        #expect(MemoryLayout<BuiltinUniforms>.stride == 64)
    }
}

enum TestSkip: Error {
    case noDevice
}
