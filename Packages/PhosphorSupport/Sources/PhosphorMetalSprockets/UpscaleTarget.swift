#if canImport(MetalFX)
import Metal
import MetalFX

/// Reusable offscreen colour target for MetalFX upscaling.
///
/// The shader pipeline renders into this at a reduced resolution and the
/// scaler blows it up to the drawable. Kept out of the element tree so
/// allocation happens once per size change rather than per frame.
@preconcurrency
@MainActor
public final class UpscaleTarget {
    /// Pixel format shared by the offscreen target and the drawable. Fixed so
    /// the scaler's input and output formats always agree.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private var texture: MTLTexture?

    public init() {}

    /// Whether this device can run a MetalFX spatial scaler at all.
    public static func isSupported(device: MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    /// Returns a target of `width` × `height`, reallocating only when the size
    /// changes. Returns nil if allocation fails, in which case the caller
    /// should render at native resolution.
    public func texture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        if let texture, texture.width == width, texture.height == height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let new = device.makeTexture(descriptor: descriptor)
        new?.label = "Phosphor.UpscaleSource"
        texture = new
        return new
    }
}
#endif
