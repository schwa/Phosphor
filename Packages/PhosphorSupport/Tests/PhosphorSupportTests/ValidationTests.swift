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
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        #expect(validate(env).isEmpty)
    }

    @Test("Duplicate texture IDs surface")
    func duplicateTextures() {
        let env = PhosphorEnvironment(
            textures: [Texture(id: "image"), Texture(id: "image")],
            output: "image"
        )
        #expect(validate(env).contains(.duplicateResource("image")))
    }

    @Test("Duplicate pass IDs surface")
    func duplicatePasses() {
        let env = PhosphorEnvironment(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "a", textures: [.init(id: "image", access: .write)]),
                Pass(id: "a", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        #expect(validate(env).contains(.duplicatePass("a")))
    }

    @Test("Unknown binding texture surfaces")
    func unknownBindingTexture() {
        let env = PhosphorEnvironment(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "missing", access: .read)
                ])
            ],
            output: "image"
        )
        let diagnostics = validate(env)
        #expect(diagnostics.contains { diagnostic in
            if case .unknownResource("missing", _) = diagnostic { return true }
            return false
        })
    }

    @Test("Read/write hazard on non-swap texture")
    func readWriteHazardCase() {
        let env = PhosphorEnvironment(
            textures: [Texture(id: "image", swap: .none)],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "image", access: .read, name: "reread")
                ])
            ],
            output: "image"
        )
        #expect(validate(env).contains(.readWriteHazard(pass: "image", resource: "image")))
    }

    @Test("Same self-read is fine on a swap texture (with distinct binding names)")
    func selfReadOnSwapIsFine() {
        let env = PhosphorEnvironment(
            textures: [Texture(id: "image", swap: .endOfFrame)],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "image", access: .read, name: "feedback")
                ])
            ],
            output: "image"
        )
        #expect(validate(env).isEmpty)
    }

    @Test("Pass with no write binding is rejected")
    func passNeedsAWriteBinding() {
        let env = PhosphorEnvironment(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .read)])
            ],
            output: "image"
        )
        #expect(validate(env).contains(.passHasNoOutput(pass: "image")))
    }
}

@Suite("Codable round-trip")
struct CodableTests {
    @Test("Environment round-trips through JSONEncoder/Decoder")
    func roundTrip() throws {
        let original = PhosphorEnvironment(
            textures: [
                Texture(id: "bufA", size: .drawable, format: .rgba16Float, swap: .endOfFrame, initialContents: .zero)
            ],
            passes: [
                Pass(id: "bufA", textures: [
                    .init(id: "bufA", access: .write),
                    .init(id: "bufA", access: .read)
                ])
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
