import Foundation
@testable import PhosphorSupport
import Testing

@Suite("TextureSize")
struct TextureSizeTests {
    private func roundTrip(_ size: TextureSize) throws -> TextureSize {
        let data = try JSONEncoder().encode(size)
        return try JSONDecoder().decode(TextureSize.self, from: data)
    }

    @Test("All cases round-trip through Codable")
    func codableRoundTrip() throws {
        #expect(try roundTrip(.drawable) == .drawable)
        #expect(try roundTrip(.native) == .native)
        #expect(try roundTrip(.fixed(width: 512, height: 256)) == .fixed(width: 512, height: 256))
        #expect(try roundTrip(.scaledDrawable(0.5)) == .scaledDrawable(0.5))
    }

    @Test("native encodes as the bare string \"native\"")
    func nativeEncoding() throws {
        let data = try JSONEncoder().encode(TextureSize.native)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == "\"native\"")
    }

    @Test("Front-matter parses size = \"native\"")
    func frontMatterNative() throws {
        let source = """
        /* phosphor:environment
        output = "image"

        [[textures]]
        id = "photo"
        init = { kind = "image", file = "mandrill" }
        size = "native"

        [[textures]]
        id = "image"

        [[passes]]
        id = "image"
        textures = [
            { id = "image", access = "write" },
            { id = "photo", access = "read" },
        ]
        */
        """
        let result = PhosphorFrontMatter.parse(source)
        #expect(result.diagnostics.isEmpty)
        let photo = result.configuration.textures.first { $0.id == "photo" }
        #expect(photo?.size == .native)
    }
}
