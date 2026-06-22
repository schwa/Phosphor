import Foundation
import Metal
@testable import PhosphorSupport
import Testing

/// Scripted ``LanguageModelPort`` for testing the generator flow with no
/// network or device. Returns queued replies in order and records every
/// prompt it was asked.
private final class FakeLanguageModel: LanguageModelPort, @unchecked Sendable {
    let displayName = "Fake"
    private let replies: [GeneratedShader]
    private var index = 0
    private(set) var prompts: [String] = []

    init(replies: [GeneratedShader]) {
        self.replies = replies
    }

    func respond(to prompt: String) async throws -> GeneratedShader {
        prompts.append(prompt)
        defer { index += 1 }
        guard index < replies.count else {
            throw ShaderGeneratorError.malformedResponse(model: displayName, underlying: "no scripted reply")
        }
        return replies[index]
    }
}

private func makeShader(body: String, output: String = "image") -> GeneratedShader {
    GeneratedShader(
        title: "Test",
        body: body,
        resources: [GeneratedResource(id: output, format: .rgba32Float, pingPong: false)],
        passes: [GeneratedPass(id: output, output: output, inputs: [])],
        uniforms: [],
        outputResourceID: output,
        flipY: false
    )
}

private let validBody = """
uint2 gid [[thread_position_in_grid]];

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    uniforms.textures.image.write(float4(1), gid);
}
"""

private let brokenBody = """
uint2 gid [[thread_position_in_grid]];

kernel void image(
    device const Uniforms& uniforms [[buffer(0)]])
{
    this is not valid metal;
}
"""

@Suite("ShaderGenerator")
struct ShaderGeneratorTests {
    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }
        return device
    }

    @Test("First valid reply is returned without a retry")
    func happyPath() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        let generator = ShaderGenerator(model: fake, device: try device())
        let source = try await generator.generate(prompt: "make a thing")
        #expect(source.contains("kernel void image"))
        #expect(fake.prompts.count == 1)
    }

    @Test("A non-compiling first reply triggers exactly one retry")
    func retryOnCompileError() async throws {
        let fake = FakeLanguageModel(replies: [
            makeShader(body: brokenBody),
            makeShader(body: validBody)
        ])
        let generator = ShaderGenerator(model: fake, device: try device())
        let source = try await generator.generate(prompt: "make a thing")
        #expect(source.contains("kernel void image"))
        #expect(fake.prompts.count == 2)
        // The retry prompt carries the compiler error feedback.
        #expect(fake.prompts[1].contains("failed to compile"))
    }

    @Test("Empty body throws emptyBody")
    func emptyBodyThrows() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: "   \n  ")])
        let generator = ShaderGenerator(model: fake, device: try device())
        await #expect(throws: ShaderGeneratorError.self) {
            _ = try await generator.generate(prompt: "make a thing")
        }
    }

    @Test("Compile check is skipped when no device is available")
    func noDeviceSkipsCompile() async throws {
        // Even a broken body returns as-is when there's no device to compile.
        let fake = FakeLanguageModel(replies: [makeShader(body: brokenBody)])
        let generator = ShaderGenerator(model: fake, device: nil)
        let source = try await generator.generate(prompt: "make a thing")
        #expect(source.contains("kernel void image"))
        #expect(fake.prompts.count == 1)
    }

    @Test("Modify request embeds the existing source in the prompt")
    func modifyPromptAssembly() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        let generator = ShaderGenerator(model: fake, device: nil)
        _ = try await generator.generate(prompt: "make it red", existingSource: "EXISTING_MARKER")
        #expect(fake.prompts.count == 1)
        #expect(fake.prompts[0].contains("EXISTING_MARKER"))
        #expect(fake.prompts[0].contains("EXISTING SHADER"))
        #expect(fake.prompts[0].contains("make it red"))
    }

    @Test("Fresh request passes the prompt through unchanged")
    func freshPromptAssembly() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        let generator = ShaderGenerator(model: fake, device: nil)
        _ = try await generator.generate(prompt: "a plasma effect")
        #expect(fake.prompts[0] == "a plasma effect")
    }

    @Test("Ping-pong self-feedback yields distinct read/write binding names")
    func pingPongBindingNames() throws {
        let shader = GeneratedShader(
            title: "Life",
            body: validBody,
            resources: [GeneratedResource(id: "image", format: .rgba32Float, pingPong: true)],
            passes: [GeneratedPass(id: "image", output: "image",
                                   inputs: [GeneratedBinding(name: "iChannel0", resource: "image")])],
            uniforms: [],
            outputResourceID: "image",
            flipY: false
        )
        let config = shader.toPhosphorConfiguration()
        let pass = try #require(config.passes.first)

        let write = try #require(pass.textures.first { $0.access == .write })
        let read = try #require(pass.textures.first { $0.access == .read })
        #expect(write.id == ResourceID("image"))
        #expect(read.id == ResourceID("image"))
        // Distinct field names so the kernel-side Textures struct compiles.
        #expect(write.effectiveName == "image")
        #expect(read.effectiveName == "imagePrev")

        // And the configuration is structurally valid (no duplicateBinding).
        #expect(validate(config).isEmpty)
    }
}
