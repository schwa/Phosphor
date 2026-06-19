import Accelerate
import Foundation

/// Computes a linear-magnitude FFT spectrum from a window of mono audio
/// samples. Configured once for a fixed sample/bin count; reused every frame.
///
/// Output is normalized to roughly 0..1, low frequencies first. Magnitudes
/// are smoothed across frames so the spectrum doesn't strobe.
public final class SpectrumAnalyzer {
    public let sampleCount: Int
    public let binCount: Int

    private let log2N: vDSP_Length
    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    /// Persistent buffers reused per frame.
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    /// Last frame's magnitudes — used for cross-frame smoothing.
    private var previousMagnitudes: [Float]

    /// Linear interpolation between this-frame and previous-frame magnitudes.
    /// `0.0` = use only previous (locked), `1.0` = no smoothing.
    public var smoothing: Float = 0.4

    public init(sampleCount: Int = 1_024, binCount: Int = 512) {
        precondition(sampleCount.nonzeroBitCount == 1, "sampleCount must be a power of two")
        precondition(binCount == sampleCount / 2, "binCount must equal sampleCount/2")
        self.sampleCount = sampleCount
        self.binCount = binCount
        self.log2N = vDSP_Length(log2(Double(sampleCount)))

        guard let setup = vDSP.FFT(log2n: log2N, radix: .radix2, ofType: DSPSplitComplex.self) else {
            preconditionFailure("Failed to create vDSP FFT setup for log2n=\(log2N)")
        }
        self.fftSetup = setup

        // Hann window: 0.5 - 0.5 cos(2πi / (N-1))
        var window = [Float](repeating: 0, count: sampleCount)
        vDSP_hann_window(&window, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
        self.window = window

        self.windowed = [Float](repeating: 0, count: sampleCount)
        self.realPart = [Float](repeating: 0, count: binCount)
        self.imagPart = [Float](repeating: 0, count: binCount)
        self.magnitudes = [Float](repeating: 0, count: binCount)
        self.previousMagnitudes = [Float](repeating: 0, count: binCount)
    }

    /// Reads `samples` (length must equal `sampleCount`), runs an FFT, and
    /// writes the resulting magnitudes into `destination` (length must equal
    /// `binCount`).
    public func process(samples: UnsafePointer<Float>, into destination: UnsafeMutablePointer<Float>) {
        // Window the input.
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(sampleCount))

        // Pack windowed[N] into the split-complex form vDSP wants
        // (even samples -> real, odd samples -> imag). Then forward FFT.
        windowed.withUnsafeMutableBufferPointer { inputBuffer in
            inputBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: sampleCount / 2) { complexBuffer in
                realPart.withUnsafeMutableBufferPointer { realBuf in
                    imagPart.withUnsafeMutableBufferPointer { imagBuf in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complexBuffer, 2, &split, 1, vDSP_Length(binCount))
                        fftSetup.forward(input: split, output: &split)

                        // Magnitude = sqrt(real^2 + imag^2).
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(binCount))
                    }
                }
            }
        }

        // Normalize. vDSP's forward FFT scales by N, so divide by N/2 to land
        // roughly in [0, 1] for typical microphone input. Clamp at 1.
        var scale: Float = 1.0 / Float(sampleCount / 2)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(binCount))
        var lower: Float = 0
        var upper: Float = 1
        vDSP_vclip(magnitudes, 1, &lower, &upper, &magnitudes, 1, vDSP_Length(binCount))

        // Cross-frame smoothing: out = previous * (1-α) + current * α.
        let alpha = max(0, min(1, smoothing))
        let oneMinusAlpha = 1 - alpha
        for i in 0..<binCount {
            let smoothed = previousMagnitudes[i] * oneMinusAlpha + magnitudes[i] * alpha
            destination[i] = smoothed
            previousMagnitudes[i] = smoothed
        }
    }
}
