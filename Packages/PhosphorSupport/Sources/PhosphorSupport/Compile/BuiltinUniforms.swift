import Foundation
import simd

/// Swift mirror of the synthetic `struct Uniforms` declared by
/// ``PhosphorHeader/uniformsDecl()``.
///
/// Layout must match the MSL declaration exactly. Field order and explicit
/// padding are chosen to match Metal's struct alignment rules.
public struct BuiltinUniforms: Equatable, Sendable {
    public var time: Float
    public var timeDelta: Float
    public var frame: Float
    public var channelCount: UInt32
    public var resolution: SIMD2<Float>
    public var mouse: SIMD2<Float>
    public var mouseButtons: UInt32
    /// `1` on the frame after the drawable size changes (texture reallocation).
    /// Use this in kernels that need to (re)seed feedback state when the view
    /// resizes — e.g. Game of Life, reaction-diffusion, fluid sims.
    public var resized: UInt32
    public var mouseClickOrigin: SIMD2<Float>

    public init(
        time: Float = 0,
        timeDelta: Float = 0,
        frame: Float = 0,
        channelCount: UInt32 = 0,
        resolution: SIMD2<Float> = .zero,
        mouse: SIMD2<Float> = .zero,
        mouseButtons: UInt32 = 0,
        resized: UInt32 = 0,
        mouseClickOrigin: SIMD2<Float> = .zero
    ) {
        self.time = time
        self.timeDelta = timeDelta
        self.frame = frame
        self.channelCount = channelCount
        self.resolution = resolution
        self.mouse = mouse
        self.mouseButtons = mouseButtons
        self.resized = resized
        self.mouseClickOrigin = mouseClickOrigin
    }
}
