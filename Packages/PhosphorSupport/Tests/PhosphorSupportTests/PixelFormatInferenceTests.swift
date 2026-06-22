import CoreGraphics
import Foundation
import ImageIO
@testable import PhosphorSupport
import Testing
import UniformTypeIdentifiers

@Suite("Pixel format inference")
struct PixelFormatInferenceTests {
    @Test("auto round-trips through Codable as the bare string")
    func autoCodable() throws {
        let data = try JSONEncoder().encode(PhosphorPixelFormat.auto)
        #expect(String(decoding: data, as: UTF8.self) == "\"auto\"")
        #expect(try JSONDecoder().decode(PhosphorPixelFormat.self, from: data) == .auto)
    }

    @Test("inferredFormat maps bit depth to the closest format")
    func depthMapping() {
        func format(bits: Int, alpha: Bool = true) -> PhosphorPixelFormat {
            PhosphorRuntime.inferredFormat(from: .init(bitsPerComponent: bits, hasAlpha: alpha))
        }
        #expect(format(bits: 8) == .rgba8Unorm)
        #expect(format(bits: 1) == .rgba8Unorm)
        #expect(format(bits: 16) == .rgba16Float)
        #expect(format(bits: 32) == .rgba32Float)
    }

    @Test("imageDescriptor reads bit depth from an 8-bit PNG")
    func descriptorFromPNG() throws {
        let asset = try makeRGBA8PNGAsset(width: 4, height: 3)
        let descriptor = try #require(asset.imageDescriptor())
        #expect(descriptor.bitsPerComponent == 8)
        let size = try #require(asset.pixelSize())
        #expect(size.width == 4)
        #expect(size.height == 3)
        #expect(PhosphorRuntime.inferredFormat(from: descriptor) == .rgba8Unorm)
    }

    @Test("imageDescriptor returns nil for non-image data")
    func descriptorFromGarbage() {
        let asset = PhosphorAsset(name: "junk", data: Data([0, 1, 2, 3]))
        #expect(asset.imageDescriptor() == nil)
        #expect(asset.pixelSize() == nil)
    }

    /// Builds an 8-bit RGBA PNG in memory and wraps it as a ``PhosphorAsset``.
    private func makeRGBA8PNGAsset(width: Int, height: Int) throws -> PhosphorAsset {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return PhosphorAsset(name: "test", data: out as Data)
    }
}
