import Foundation
@testable import PhosphorSupport
import Testing

@Suite("Validation")
struct ValidationTests {
    @Test("Empty environment with declared output errors out")
    func missingOutput() {
        let env = PhosphorEnvironment(output: "image")
        let diagnostics = validate(env)
        #expect(diagnostics.contains(.missingOutput("image")))
    }

    @Test("Single-pass canonical environment validates cleanly")
    func singlePassClean() {
        let env = PhosphorEnvironment(
            resources: [
                .texture2D(id: "image", spec: .init(pingPong: true))
            ],
            passes: [
                Pass(id: "image", inputs: [.init(name: "iChannel0", resource: "image")], output: "image")
            ],
            output: "image"
        )
        #expect(validate(env).isEmpty)
    }

    @Test("Duplicate resource IDs surface")
    func duplicateResources() {
        let env = PhosphorEnvironment(
            resources: [
                .texture2D(id: "image", spec: .init()),
                .texture2D(id: "image", spec: .init())
            ],
            output: "image"
        )
        #expect(validate(env).contains(.duplicateResource("image")))
    }

    @Test("Duplicate pass IDs surface")
    func duplicatePasses() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init())],
            passes: [
                Pass(id: "a", output: "image"),
                Pass(id: "a", output: "image")
            ],
            output: "image"
        )
        #expect(validate(env).contains(.duplicatePass("a")))
    }

    @Test("Unknown binding resource surfaces")
    func unknownBindingResource() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init())],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel0", resource: "missing")],
                    output: "image"
                )
            ],
            output: "image"
        )
        let diagnostics = validate(env)
        #expect(diagnostics.contains { diagnostic in
            if case .unknownResource("missing", _) = diagnostic { return true }return false
        })
    }

    @Test("Channel name must be iChannelN")
    func badChannelName() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "feedback", resource: "image")],
                    output: "image"
                )
            ],
            output: "image"
        )
        #expect(validate(env).contains(.unknownChannelName("feedback", in: "image")))
    }

    @Test("Read/write hazard on non-pingpong resource")
    func readWriteHazardCase() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: false))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel0", resource: "image")],
                    output: "image"
                )
            ],
            output: "image"
        )
        #expect(validate(env).contains(.readWriteHazard(pass: "image", resource: "image")))
    }

    @Test("Same self-read is fine on a ping-pong resource")
    func selfReadOnPingPongIsFine() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel0", resource: "image")],
                    output: "image"
                )
            ],
            output: "image"
        )
        #expect(validate(env).isEmpty)
    }

    @Test("Duplicate binding name on one pass")
    func duplicateBindingName() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [
                        .init(name: "iChannel0", resource: "image"),
                        .init(name: "iChannel0", resource: "image")
                    ],
                    output: "image"
                )
            ],
            output: "image"
        )
        #expect(validate(env).contains(.duplicateBinding(name: "iChannel0", in: "image")))
    }
}

@Suite("Channel inference")
struct ChannelInferenceTests {
    @Test("No bindings -> 0 channels")
    func noChannels() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init())],
            passes: [Pass(id: "image", output: "image")],
            output: "image"
        )
        #expect(channelCount(for: env) == 0)
    }

    @Test("iChannel0 used -> 1 channel")
    func oneChannel() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel0", resource: "image")],
                    output: "image"
                )
            ],
            output: "image"
        )
        #expect(channelCount(for: env) == 1)
    }

    @Test("iChannel3 used -> 4 channels (sparse usage rounds up)")
    func sparseUsage() {
        let env = PhosphorEnvironment(
            resources: [.texture2D(id: "image", spec: .init(pingPong: true))],
            passes: [
                Pass(
                    id: "image",
                    inputs: [.init(name: "iChannel3", resource: "image")],
                    output: "image"
                )
            ],
            output: "image"
        )
        #expect(channelCount(for: env) == 4)
    }

    @Test("channelIndex parses iChannelN")
    func indexParsing() {
        #expect(channelIndex(from: "iChannel0") == 0)
        #expect(channelIndex(from: "iChannel12") == 12)
        #expect(channelIndex(from: "iChannel") == nil)
        #expect(channelIndex(from: "iChannelA") == nil)
        #expect(channelIndex(from: "feedback") == nil)
    }
}

@Suite("Codable round-trip")
struct CodableTests {
    @Test("Environment round-trips through JSONEncoder/Decoder")
    func roundTrip() throws {
        let original = PhosphorEnvironment(
            resources: [
                .texture2D(id: "bufA", spec: .init(
                    size: .drawable,
                    format: .rgba16Float,
                    pingPong: true,
                    flipTiming: .endOfFrame,
                    initial: .zero
                ))
            ],
            passes: [
                Pass(
                    id: "bufA",
                    inputs: [.init(name: "iChannel0", resource: "bufA")],
                    output: "bufA"
                )
            ],
            output: "bufA",
            uniforms: [
                UniformDecl(
                    name: "intensity",
                    kind: .float,
                    defaultValue: .float(1.0),
                    ui: .slider(min: 0.0, max: 4.0)
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhosphorEnvironment.self, from: data)
        #expect(decoded == original)
    }
}
