import Foundation
import simd

/// A named GPU resource declared by a ``PhosphorEnvironment``.
///
/// Phosphor 2.0 only supports 2D textures. The enum exists so future versions
/// can add buffers, cubemaps, etc. without changing call sites.
public enum Resource: Hashable, Sendable {
    case texture2D(id: ResourceID, spec: Texture2DSpec)
    /// A read-only image asset bound by name. Format and size are
    /// determined by the decoded image — callers don't pre-declare them.
    case image(id: ResourceID, name: String, access: TextureAccess)

    public var id: ResourceID {
        switch self {
        case .texture2D(let id, _): return id
        case .image(let id, _, _): return id
        }
    }

    /// The MSL access qualifier the kernel-side `iChannelN` binding should
    /// use for this resource. Texture2D resources default to `.read` (the
    /// historical behavior); image resources can opt into `.sample` via
    /// front-matter.
    public var access: TextureAccess {
        switch self {
        case .texture2D: return .read
        case .image(_, _, let access): return access
        }
    }
}

/// MSL access qualifier for a channel binding's `texture2d<float, ...>`.
///
/// `.read` is integer-pixel access via `.read(coord)`; `.sample` is
/// `.sample(sampler, uv)` with optional filtering.
public enum TextureAccess: String, Hashable, Codable, Sendable {
    case read
    case sample
}

/// Describes a 2D texture resource: size, format, ping-pong behavior, initial contents.
public struct Texture2DSpec: Hashable, Sendable, Codable {
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

    private enum CodingKeys: String, CodingKey {
        case size
        case format
        case pingPong
        case flipTiming
        case initial
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.size = try container.decodeIfPresent(TextureSize.self, forKey: .size) ?? .drawable
        self.format = try container.decodeIfPresent(PhosphorPixelFormat.self, forKey: .format) ?? .rgba32Float
        self.pingPong = try container.decodeIfPresent(Bool.self, forKey: .pingPong) ?? false
        self.flipTiming = try container.decodeIfPresent(FlipTiming.self, forKey: .flipTiming) ?? .endOfFrame
        self.initial = try container.decodeIfPresent(TextureInit.self, forKey: .initial) ?? .zero
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(format, forKey: .format)
        try container.encode(pingPong, forKey: .pingPong)
        try container.encode(flipTiming, forKey: .flipTiming)
        try container.encode(initial, forKey: .initial)
    }
}

/// How a texture's pixel dimensions are derived at materialization.
///
/// - `.drawable`: matches the host's drawable size; reallocated on resize.
/// - `.fixed`: fixed pixel dimensions; survives drawable resize.
/// - `.scaledDrawable(s)`: drawable size times `s`, rounded to nearest pixel.
public enum TextureSize: Hashable, Sendable {
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
public enum TextureInit: Hashable, Sendable {
    case zero
    case color(SIMD4<Float>)
    /// Resolved through the host-injected asset registry by string key.
    case image(name: String)
    case noise(seed: UInt64)
}
