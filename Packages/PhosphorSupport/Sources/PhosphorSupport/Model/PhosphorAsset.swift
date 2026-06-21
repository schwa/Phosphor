import CoreGraphics
import Foundation
import ImageIO

/// A bundled binary asset referenced by name from a Phosphor configuration.
///
/// v1 only supports image assets, used to seed textures whose
/// ``TextureInit`` is `.image(name:)`. The asset's `name` is the lookup
/// key inside `PhosphorConfiguration.uniforms` / texture specs; the bytes
/// are decoded to a `CGImage` on demand.
public struct PhosphorAsset: Hashable, Sendable {
    /// Logical name used to reference the asset from front-matter.
    /// Conventionally matches the on-disk filename without extension, but
    /// the runtime treats it as opaque.
    public let name: String
    /// Raw file bytes (PNG / JPEG / any format accepted by ImageIO).
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// Decode the bytes into a `CGImage`. Returns `nil` when the data
    /// isn't recognized by ImageIO. Cheap to call repeatedly — callers
    /// should still cache the result if they need it more than once per
    /// asset.
    public func makeCGImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
