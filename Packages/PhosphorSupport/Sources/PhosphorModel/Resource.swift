import Foundation
import simd

/// A named texture resource declared by a ``PhosphorConfiguration``.
///
/// Phosphor's runtime only deals in 2D textures, so there's no enum to
/// distinguish kinds. Properties cover sizing, format, swap (ping-pong)
/// timing, and an init action describing initial contents. Per-pass
/// usage (the access mode) lives on ``Pass/TextureBinding``, not here.
public struct Texture: Hashable, Sendable {
    public var id: ResourceID
    public var size: TextureSize
    public var format: PhosphorPixelFormat
    public var swap: SwapTiming
    public var initialContents: TextureInit

    public init(
        id: ResourceID,
        size: TextureSize = .drawable,
        format: PhosphorPixelFormat = .rgba32Float,
        swap: SwapTiming = .none,
        initialContents: TextureInit = .zero
    ) {
        self.id = id
        self.size = size
        self.format = format
        self.swap = swap
        self.initialContents = initialContents
    }
}

/// How a texture's pixel dimensions are derived at materialization.
///
/// - `.drawable`: matches the host's drawable size; reallocated on resize.
/// - `.fixed`: fixed pixel dimensions; survives drawable resize.
/// - `.scaledDrawable(s)`: drawable size times `s`, rounded to nearest pixel.
///
/// Image-init textures ignore this field entirely: they are always sized to
/// the decoded image's native dimensions.
public enum TextureSize: Hashable, Sendable {
    case drawable
    case fixed(width: Int, height: Int)
    case scaledDrawable(Float)
}

/// Pixel format options. Maps to `MTLPixelFormat` at runtime.
///
/// Image-init textures ignore this field entirely: they use whatever format
/// the image decodes to.
public enum PhosphorPixelFormat: String, Hashable, Codable, Sendable, CaseIterable {
    case rgba8Unorm
    case bgra8Unorm
    case rgba16Float
    case rgba32Float
}

/// When the ping-pong swap happens for a texture.
///
/// - `.none`: no ping-pong. Single texture; the same handle is bound for
///   read and write.
/// - `.endOfFrame`: ping-pong, flip once at end of frame; later passes in
///   the same frame see *last* frame's contents at the read parity.
///   Shadertoy semantics.
/// - `.immediate`: flip parity right after the writing pass; later passes
///   in the same frame see the just-written data at the read parity.
///   Modeled but not yet implemented (see #4 / #54).
public enum SwapTiming: String, Hashable, Codable, Sendable {
    case none
    case endOfFrame
    case immediate
}

/// Initial contents for a texture, applied once at materialization (and on
/// reallocation after resize).
///
/// `.zero` is a shortcut for `.fill([0, 0, 0, 0])`. They round-trip
/// identically at the GPU level but the TOML distinguishes them so authors
/// can write `init = { kind = "zero" }` for the common case.
public enum TextureInit: Hashable, Sendable {
    case zero
    case fill(SIMD4<Float>)
    /// Looks up an asset by filename (with extension) in the host-injected
    /// asset registry and decodes it as the texture's initial contents.
    case image(file: String)
    case noise(seed: UInt64)
}

/// MSL access qualifier for a per-pass texture binding.
///
/// - `.read`: integer-pixel access via `.read(coord)`.
/// - `.sample`: filtered sampling via `.sample(sampler, uv)` (also supports `.read`).
/// - `.write`: kernel writes through this binding.
/// - `.readWrite`: simultaneous read and write. Modeled but currently
///   unsupported at runtime; passes that declare it will fail validation.
public enum TextureAccess: String, Hashable, Codable, Sendable {
    case read
    case sample
    case write
    case readWrite
}
