#if canImport(MetalFX)
import Metal
import MetalSprockets
import QuartzCore

/// Upscales `sourceTexture` into the current drawable with MetalFX spatial
/// scaling.
///
/// Exists because ``MetalSprockets/MetalFXSpatial`` needs its output texture as
/// a value, and the drawable is only reachable through the element
/// environment.
public struct PhosphorUpscaleElement: Element {
    var sourceTexture: MTLTexture

    @MSEnvironment(\.currentDrawable)
    var currentDrawable

    public init(sourceTexture: MTLTexture) {
        self.sourceTexture = sourceTexture
    }

    public var body: some Element {
        if let currentDrawable {
            MetalFXSpatial(inputTexture: sourceTexture, outputTexture: currentDrawable.texture)
        }
    }
}
#endif
