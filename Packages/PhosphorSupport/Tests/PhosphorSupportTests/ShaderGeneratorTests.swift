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

    var plannedApproach: PlannedApproach?
    private(set) var planPrompts: [String] = []

    func respondPlan(to prompt: String) async throws -> PlannedApproach {
        planPrompts.append(prompt)
        guard let plannedApproach else {
            throw ShaderGeneratorError.malformedResponse(model: displayName, underlying: "no scripted plan")
        }
        return plannedApproach
    }
}

/// Scripted port whose first response throws (simulating a decode failure)
/// and whose subsequent responses come from `replies`.
private final class ThrowFirstLanguageModel: LanguageModelPort, @unchecked Sendable {
    let displayName = "Fake"
    private let firstError: ShaderGeneratorError
    private let replies: [GeneratedShader]
    private var index = 0
    private(set) var prompts: [String] = []

    init(firstError: ShaderGeneratorError, then replies: [GeneratedShader]) {
        self.firstError = firstError
        self.replies = replies
    }

    func respond(to prompt: String) async throws -> GeneratedShader {
        prompts.append(prompt)
        defer { index += 1 }
        if index == 0 { throw firstError }
        guard index - 1 < replies.count else {
            throw ShaderGeneratorError.malformedResponse(model: displayName, underlying: "no scripted reply")
        }
        return replies[index - 1]
    }

    func respondPlan(to _: String) async throws -> PlannedApproach {
        throw ShaderGeneratorError.malformedResponse(model: displayName, underlying: "no scripted plan")
    }
}

private func makeShader(body: String, output: String = "image") -> GeneratedShader {
    GeneratedShader(
        title: "Test",
        body: body,
        resources: [GeneratedResource(id: output, format: .rgba32Float, pingPong: false, imageFile: "")],
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
        let result = try await generator.generate(prompt: "make a thing")
        #expect(result.source.contains("kernel void image"))
        #expect(fake.prompts.count == 1)
    }

    @Test("A non-compiling first reply triggers exactly one retry")
    func retryOnCompileError() async throws {
        let fake = FakeLanguageModel(replies: [
            makeShader(body: brokenBody),
            makeShader(body: validBody)
        ])
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "make a thing")
        #expect(result.source.contains("kernel void image"))
        #expect(fake.prompts.count == 2)
        // The retry prompt carries the compiler error feedback.
        #expect(fake.prompts[1].contains("failed to compile"))
        // The corrected error survives on the result (#96).
        #expect(result.corrections.count == 1)
        #expect(result.corrections.first?.kind == .compile)
        #expect(result.corrections.first?.attempt == 1)
        #expect(!(result.corrections.first?.message.isEmpty ?? true))
    }

    @Test("A first-try success records no corrections")
    func noCorrectionsOnSuccess() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "make a thing")
        #expect(result.corrections.isEmpty)
    }

    @Test("A malformed first response triggers exactly one decode retry")
    func retryOnDecodeError() async throws {
        let fake = ThrowFirstLanguageModel(
            firstError: .malformedResponse(model: "Fake", underlying: "missing title"),
            then: [makeShader(body: validBody)]
        )
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "make a thing")
        #expect(result.source.contains("kernel void image"))
        #expect(fake.prompts.count == 2)
        // The retry prompt asks for a complete, well-formed response.
        #expect(fake.prompts[1].contains("could not be decoded"))
        // The decode failure survives on the result.
        #expect(result.corrections.count == 1)
        #expect(result.corrections.first?.kind == .decode)
        #expect(result.corrections.first?.message == "missing title")
    }

    @Test("Only one corrective retry: a decode retry that won't compile is returned as-is")
    func decodeRetryDoesNotStackCompileRetry() async throws {
        // First call throws (decode), retry returns a non-compiling shader.
        // The single retry is already spent, so we must NOT retry again.
        let fake = ThrowFirstLanguageModel(
            firstError: .malformedResponse(model: "Fake", underlying: "bad"),
            then: [makeShader(body: brokenBody)]
        )
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "make a thing")
        // Exactly two model turns: initial (threw) + one retry. No third.
        #expect(fake.prompts.count == 2)
        #expect(result.corrections.count == 1)
        #expect(result.corrections.first?.kind == .decode)
    }

    @Test("Planning mode runs a plan turn then a codegen turn")
    func planningRunsTwoTurns() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        fake.plannedApproach = PlannedApproach(
            intent: "a swirling galaxy",
            shape: .singlePassImage,
            plan: "Sample uv, build a spiral with time."
        )
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "a galaxy", plan: true)

        // One plan turn + one codegen turn.
        #expect(fake.planPrompts.count == 1)
        #expect(fake.prompts.count == 1)
        // The codegen prompt carries the plan and the verbatim original prompt.
        #expect(fake.prompts[0].contains("a swirling galaxy"))
        #expect(fake.prompts[0].contains("a galaxy"))
        // The plan is preserved on the result, with the verbatim prompt attached.
        #expect(result.plan?.intent == "a swirling galaxy")
        #expect(result.plan?.originalPrompt == "a galaxy")
        #expect(result.plan?.shape == .singlePassImage)
        #expect(result.source.contains("kernel void image"))
    }

    @Test("Without planning, no plan turn runs and result.plan is nil")
    func noPlanningByDefault() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "a galaxy")
        #expect(fake.planPrompts.isEmpty)
        #expect(result.plan == nil)
    }

    @Test("Exchanges record every model turn (request + response)")
    func exchangesRecorded() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: validBody)])
        fake.plannedApproach = PlannedApproach(intent: "x", shape: .singlePassImage, plan: "do x")
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "a galaxy", plan: true)
        // One plan exchange + one codegen exchange.
        #expect(result.exchanges.count == 2)
        #expect(result.exchanges[0].kind == .plan)
        #expect(result.exchanges[0].response?.approach?.intent == "x")
        #expect(result.exchanges[1].kind == .codegen)
        #expect(result.exchanges[1].response?.shader?.body.contains("kernel void image") == true)
        #expect(result.exchanges.allSatisfy { !$0.request.isEmpty })
    }

    @Test("A compile retry records two codegen-side exchanges")
    func exchangesIncludeRetry() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: brokenBody), makeShader(body: validBody)])
        let generator = ShaderGenerator(model: fake, device: try device())
        let result = try await generator.generate(prompt: "a thing")
        #expect(result.exchanges.count == 2)
        #expect(result.exchanges[0].kind == .codegen)
        #expect(result.exchanges[1].kind == .compileRetry)
    }

    @Test("A persistently malformed model rethrows after the single retry")
    func decodeRetryGivesUp() async throws {
        // First call throws, retry has no scripted reply -> throws again.
        let fake = ThrowFirstLanguageModel(
            firstError: .malformedResponse(model: "Fake", underlying: "bad"),
            then: []
        )
        let generator = ShaderGenerator(model: fake, device: try device())
        // generate() wraps the underlying error in GenerationFailure so the
        // exchanges survive (#99).
        await #expect(throws: GenerationFailure.self) {
            _ = try await generator.generate(prompt: "make a thing")
        }
        #expect(fake.prompts.count == 2)
    }

    @Test("Empty body throws emptyBody (wrapped in GenerationFailure)")
    func emptyBodyThrows() async throws {
        let fake = FakeLanguageModel(replies: [makeShader(body: "   \n  ")])
        let generator = ShaderGenerator(model: fake, device: try device())
        let failure = await #expect(throws: GenerationFailure.self) {
            _ = try await generator.generate(prompt: "make a thing")
        }
        // The real cause is still reachable, and exchanges were captured.
        if case .emptyBody = failure?.underlying as? ShaderGeneratorError {} else {
            Issue.record("expected emptyBody underlying")
        }
        #expect(failure?.exchanges.isEmpty == false)
    }

    @Test("Compile check is skipped when no device is available")
    func noDeviceSkipsCompile() async throws {
        // Even a broken body returns as-is when there's no device to compile.
        let fake = FakeLanguageModel(replies: [makeShader(body: brokenBody)])
        let generator = ShaderGenerator(model: fake, device: nil)
        let result = try await generator.generate(prompt: "make a thing")
        #expect(result.source.contains("kernel void image"))
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
            resources: [GeneratedResource(id: "image", format: .rgba32Float, pingPong: true, imageFile: "")],
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

    @Test("A resource with imageFile maps to an image-init texture")
    func imageFileMapsToImageInit() throws {
        let shader = GeneratedShader(
            title: "Tinted Mandrill",
            body: validBody,
            resources: [
                GeneratedResource(id: "image", format: .rgba32Float, pingPong: false, imageFile: ""),
                GeneratedResource(id: "src", format: .rgba32Float, pingPong: false, imageFile: "builtin:mandrill")
            ],
            passes: [GeneratedPass(id: "image", output: "image",
                                   inputs: [GeneratedBinding(name: "iChannel0", resource: "src")])],
            uniforms: [],
            outputResourceID: "image",
            flipY: false
        )
        let config = shader.toPhosphorConfiguration()
        let src = try #require(config.textures.first { $0.id == ResourceID("src") })
        let out = try #require(config.textures.first { $0.id == ResourceID("image") })
        #expect(src.initialContents == .image(file: "builtin:mandrill"))
        // Empty imageFile stays a plain zero-init compute target.
        #expect(out.initialContents == .zero)
    }
}
