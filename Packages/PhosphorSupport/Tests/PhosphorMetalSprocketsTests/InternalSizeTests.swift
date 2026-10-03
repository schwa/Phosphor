import Foundation
@testable import PhosphorMetalSprockets
import Testing

@Suite("Upscaling internal size")
struct InternalSizeTests {
    private func size(_ width: Double, _ height: Double, scale: Double) -> CGSize {
        PhosphorMetalSprocketsView.internalSize(
            for: CGSize(width: width, height: height),
            scale: scale
        )
    }

    @Test("Scales below 1 shrink the render target")
    func scalesDown() {
        #expect(size(1_000, 800, scale: 0.5) == CGSize(width: 500, height: 400))
        #expect(size(1_000, 800, scale: 0.75) == CGSize(width: 750, height: 600))
    }

    @Test("Fractional results are rounded, not truncated")
    func rounds() {
        #expect(size(101, 101, scale: 0.5) == CGSize(width: 51, height: 51))
        #expect(size(3, 3, scale: 2.0 / 3.0) == CGSize(width: 2, height: 2))
    }

    /// Native and over-native scales must render straight into the drawable, so
    /// the default path stays byte-for-byte what it was before upscaling
    /// existed.
    @Test("Scales at or above 1 pass the drawable size through", arguments: [1.0, 1.5, 2.0])
    func passesThroughAtNative(scale: Double) {
        #expect(size(1_000, 800, scale: scale) == CGSize(width: 1_000, height: 800))
    }

    /// A degenerate scale must not produce a zero-sized texture.
    @Test("Nonsense scales fall back to the drawable size", arguments: [0.0, -1.0])
    func rejectsDegenerateScales(scale: Double) {
        #expect(size(1_000, 800, scale: scale) == CGSize(width: 1_000, height: 800))
    }

    @Test("A scale that would round to zero falls back to the drawable size")
    func rejectsSubPixelResults() {
        #expect(size(1, 1, scale: 0.01) == CGSize(width: 1, height: 1))
    }
}
