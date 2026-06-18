import Foundation
import simd

/// A named GPU resource declared by a ``PhosphorEnvironment``.
///
/// Phosphor 2.0 only supports 2D textures. The enum exists so future versions
/// can add buffers, cubemaps, etc. without changing call sites.
public enum Resource: Hashable, Codable, Sendable {
    case texture2D(id: ResourceID, spec: Texture2DSpec)

    public var id: ResourceID {
        switch self {
        case .texture2D(let id, _): return id
        }
    }
}

/// Describes a 2D texture resource: size, format, ping-pong behavior, initial contents.
public struct Texture2DSpec: Hashable, Codable, Sendable {
    public var size: TextureSize
    public var format: PhosphorPixelFormat
    public var pingPong: Bool
    public var flipTiming: FlipTiming
    public var initial: TextureInit

    public init(
        size: TextureSize = .drawable,
        format: PhosphorPixelFormat = .rgba32Float,
        pingPong: Bool = false,
        flipTiming: FlipTiming = .endOfFrame,
        initial: TextureInit = .zero
    ) {
        self.size = size
        self.format = format
        self.pingPong = pingPong
        self.flipTiming = flipTiming
        self.initial = initial
    }
}

/// How a texture's pixel dimensions are derived at materialization.
///
/// - `.drawable`: matches the host's drawable size; reallocated on resize.
/// - `.fixed`: fixed pixel dimensions; survives drawable resize.
/// - `.scaledDrawable(s)`: drawable size times `s`, rounded to nearest pixel.
public enum TextureSize: Hashable, Codable, Sendable {
    case drawable
    case fixed(width: Int, height: Int)
    case scaledDrawable(Float)
}

/// Pixel format options. Maps to `MTLPixelFormat` at runtime.
public enum PhosphorPixelFormat: String, Hashable, Codable, Sendable {
    case rgba8Unorm
    case rgba16Float
    case rgba32Float
}

/// When the ping-pong swap happens for a ``Texture2DSpec`` with `pingPong == true`.
///
/// - `.endOfFrame`: flip once at end of frame; later passes in the same frame
///   see *last* frame's contents. Shadertoy semantics.
/// - `.immediate`: flip right after the writing pass; later passes in the same
///   frame see *this* frame's just-written contents. Requires inter-dispatch
///   synchronization; not implemented until a later milestone.
public enum FlipTiming: String, Hashable, Codable, Sendable {
    case endOfFrame
    case immediate
}

/// Initial contents for a texture, applied once at materialization (and on
/// reallocation after resize).
public enum TextureInit: Hashable, Codable, Sendable {
    case zero
    case color(SIMD4<Float>)
    /// Resolved through the host-injected asset registry by string key.
    case image(name: String)
    case noise(seed: UInt64)
}
