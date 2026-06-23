import Foundation
@testable import PhosphorModel
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
        #expect(try roundTrip(.fixed(width: 512, height: 256)) == .fixed(width: 512, height: 256))
        #expect(try roundTrip(.scaledDrawable(0.5)) == .scaledDrawable(0.5))
    }

    @Test("drawable encodes as the bare string \"drawable\"")
    func drawableEncoding() throws {
        let data = try JSONEncoder().encode(TextureSize.drawable)
        #expect(String(decoding: data, as: UTF8.self) == "\"drawable\"")
    }
}
