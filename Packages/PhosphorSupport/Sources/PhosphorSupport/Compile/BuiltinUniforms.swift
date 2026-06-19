import Foundation
import Metal
import simd

/// Swift mirror of the leading fields of the per-pass `struct Uniforms`
/// declared by ``PhosphorHeader/uniformsDecl(pass:)``.
///
/// The kernel side's `Uniforms` argument buffer ends with a `Textures`
/// member whose layout depends on the binding count for that pass. This
/// Swift struct only carries the *fixed* prefix (scalars + audio
/// pointers); the runtime is responsible for appending the texture
/// handles into the same buffer at the right offset.
///
/// Field order and explicit padding match Metal's struct alignment rules.
public struct BuiltinUniforms: Equatable, Sendable {
    public var time: Float
    public var timeDelta: Float
    public var frame: Float
    public var resolution: SIMD2<Float>
    public var mouse: SIMD2<Float>
    public var mouseButtons: UInt32
    /// `1` on the frame after the drawable size changes (texture reallocation).
    /// Use this in kernels that need to (re)seed feedback state when the view
    /// resizes — e.g. Game of Life, reaction-diffusion, fluid sims.
    public var resized: UInt32
    public var mouseClickOrigin: SIMD2<Float>
    /// GPU address of the audio waveform buffer. Always populated; zero-filled
    /// when the microphone input is disabled or unavailable.
    public var waveform: UInt64
    /// GPU address of the audio FFT magnitude buffer. Always populated;
    /// zero-filled when the microphone input is disabled or unavailable.
    public var spectrum: UInt64

    public init(
        time: Float = 0,
        timeDelta: Float = 0,
        frame: Float = 0,
        resolution: SIMD2<Float> = .zero,
        mouse: SIMD2<Float> = .zero,
        mouseButtons: UInt32 = 0,
        resized: UInt32 = 0,
        mouseClickOrigin: SIMD2<Float> = .zero,
        waveform: UInt64 = 0,
        spectrum: UInt64 = 0
    ) {
        self.time = time
        self.timeDelta = timeDelta
        self.frame = frame
        self.resolution = resolution
        self.mouse = mouse
        self.mouseButtons = mouseButtons
        self.resized = resized
        self.mouseClickOrigin = mouseClickOrigin
        self.waveform = waveform
        self.spectrum = spectrum
    }
}
