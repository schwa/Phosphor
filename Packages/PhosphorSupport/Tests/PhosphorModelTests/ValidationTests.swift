import Foundation
@testable import PhosphorModel
import Testing

@Suite("Validation")
struct ValidationTests {
    @Test("Empty configuration with declared output errors out")
    func missingOutput() {
        let config = PhosphorConfiguration(output: "image")
        let diagnostics = validate(config)
        #expect(diagnostics.contains(.missingOutput("image")))
    }

    @Test("An image-init texture marked ping-pong is rejected")
    func imageTexturePingPong() {
        let config = PhosphorConfiguration(
            textures: [
                Texture(id: "photo", swap: .endOfFrame, initialContents: .image(file: "x.png")),
                Texture(id: "image")
            ],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "photo", access: .read)
                ])
            ],
            output: "image"
        )
        let diagnostics = validate(config)
        #expect(diagnostics.contains(.imageTextureCannotPingPong("photo")))
    }

    @Test("An image-init texture without ping-pong validates cleanly")
    func imageTextureNoPingPong() {
        let config = PhosphorConfiguration(
            textures: [
                Texture(id: "photo", initialContents: .image(file: "x.png")),
                Texture(id: "image")
            ],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "photo", access: .read)
                ])
            ],
            output: "image"
        )
        #expect(!validate(config).contains(.imageTextureCannotPingPong("photo")))
    }

    @Test("Single-pass canonical configuration validates cleanly")
    func singlePassClean() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        #expect(validate(config).isEmpty)
    }

    @Test("Duplicate texture IDs surface")
    func duplicateTextures() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image"), Texture(id: "image")],
            output: "image"
        )
        #expect(validate(config).contains(.duplicateResource("image")))
    }

    @Test("Duplicate pass IDs surface")
    func duplicatePasses() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "a", textures: [.init(id: "image", access: .write)]),
                Pass(id: "a", textures: [.init(id: "image", access: .write)])
            ],
            output: "image"
        )
        #expect(validate(config).contains(.duplicatePass("a")))
    }

    @Test("Unknown binding texture surfaces")
    func unknownBindingTexture() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "missing", access: .read)
                ])
            ],
            output: "image"
        )
        let diagnostics = validate(config)
        #expect(diagnostics.contains { diagnostic in
            if case .unknownResource("missing", _) = diagnostic { return true }
            return false
        })
    }

    @Test("Read/write hazard on non-swap texture")
    func readWriteHazardCase() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image", swap: .none)],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "image", access: .read, name: "reread")
                ])
            ],
            output: "image"
        )
        #expect(validate(config).contains(.readWriteHazard(pass: "image", resource: "image")))
    }

    @Test("Same self-read is fine on a swap texture (with distinct binding names)")
    func selfReadOnSwapIsFine() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image", swap: .endOfFrame)],
            passes: [
                Pass(id: "image", textures: [
                    .init(id: "image", access: .write),
                    .init(id: "image", access: .read, name: "feedback")
                ])
            ],
            output: "image"
        )
        #expect(validate(config).isEmpty)
    }

    @Test("Pass with no write binding is rejected")
    func passNeedsAWriteBinding() {
        let config = PhosphorConfiguration(
            textures: [Texture(id: "image")],
            passes: [
                Pass(id: "image", textures: [.init(id: "image", access: .read)])
            ],
            output: "image"
        )
        #expect(validate(config).contains(.passHasNoOutput(pass: "image")))
    }
}

@Suite("Codable round-trip")
struct CodableTests {
    @Test("Environment round-trips through JSONEncoder/Decoder")
    func roundTrip() throws {
        let original = PhosphorConfiguration(
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
        let decoded = try JSONDecoder().decode(PhosphorConfiguration.self, from: data)
        #expect(decoded == original)
    }
}
