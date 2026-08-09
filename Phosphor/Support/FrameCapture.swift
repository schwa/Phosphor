import CoreImage
import Metal
import PhosphorModel
import PhosphorRuntime
import UniformTypeIdentifiers

/// Reads the shader's most recently rendered output back off the GPU.
///
/// Captures the texture the renderer last blitted to the drawable, so what you
/// get is the shader output at drawable resolution with no UI chrome — not a
/// re-render, so feedback shaders aren't advanced by taking a picture.
enum FrameCapture {
    /// Returns the last-rendered contents of `displayedResource` (or the
    /// configuration's declared output).
    ///
    /// - Parameter frameIndex: the frame counter the renderer used for its most
    ///   recent frame. Ping-pong resources alternate halves by frame parity, so
    ///   this picks the half that was actually drawn.
    static func image(
        runtime: PhosphorRuntime,
        displayedResource: ResourceID?,
        frameIndex: UInt32
    ) -> CGImage? {
        let resourceID: ResourceID = {
            if let displayedResource, runtime.textures[displayedResource] != nil {
                return displayedResource
            }
            return runtime.configuration.output
        }()
        guard let pair = runtime.textures[resourceID] else { return nil }

        // Mirrors PhosphorRenderer: even frames use parity A. Non-ping-pong
        // resources have a == b, so parity is irrelevant for them.
        let isEvenFrame = (UInt64(frameIndex) % 2) == 0
        let isParityA = pair.pingPong ? isEvenFrame : true
        let texture = pair.writeTexture(currentIsA: isParityA)

        return image(of: texture, device: runtime.device, flipY: runtime.configuration.flipY)
    }

    /// Wraps an `MTLTexture` as a `CGImage` in the orientation the billboard
    /// puts on screen. Core Image handles the pixel-format conversion, so this
    /// works for the float formats shaders often render into as well as the
    /// 8-bit ones.
    ///
    /// - Parameter flipY: the configuration's flag. Core Image reads a Metal
    ///   texture bottom-up, so the default orientation needs a vertical flip to
    ///   land right way up in a `CGImage`; `flipY` shaders are already drawn
    ///   inverted on screen, so they want the unflipped conversion.
    static func image(of texture: MTLTexture, device: MTLDevice, flipY: Bool = false) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ciImage = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        let oriented = flipY ? ciImage : ciImage.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -ciImage.extent.height)
        )
        let context = CIContext(mtlDevice: device)
        return context.createCGImage(
            oriented,
            from: oriented.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }

    /// Encodes `image` for `contentType`. Returns nil for a type
    /// ImageIO can't write.
    static func encode(_ image: CGImage, as contentType: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            contentType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
