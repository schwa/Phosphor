import MetalSprocketsUI
import Observation
import PhosphorModel
import PhosphorCompile
import PhosphorGeneration
import PhosphorRuntime

/// Per-document editor session state.
///
/// Holds the UI/session state that the editor view tree would otherwise
/// thread through as a long parameter list: playback intent, the previewed
/// resource, and live user-uniform values. Document text/parsing stays with
/// the document; GPU state stays with ``PhosphorRuntime``. This is expected
/// to grow as more session state moves off individual views.
@Observable
@MainActor
final class EditorModel {
    /// When `true`, the kernel sees frozen time and frame values.
    var isPaused: Bool = false

    /// Each new value triggers a one-shot reset (time → 0, feedback reseed).
    var resetSignal: Int = 0

    /// Which resource the preview blits to the drawable. `nil` follows the
    /// configuration's declared output (the normal case).
    var displayedResource: ResourceID?

    /// Live user-uniform values, shared between the render surface and the
    /// uniforms panel. Seeded from the configuration's declared defaults.
    var uniformValues: [String: UniformValue] = [:]

    /// Most recent frame-timing statistics from the render surface, used to
    /// drive the FPS / timing overlay. `nil` until the first frame.
    var frameTimingStatistics: FrameTimingStatistics?

    init() {}

    /// Fire a one-shot reset and resume playback.
    func reset() {
        resetSignal &+= 1
        isPaused = false
    }

    /// Reseed `uniformValues` from a configuration's declared defaults.
    func seedUniformDefaults(for configuration: PhosphorConfiguration) {
        uniformValues = UserUniformsLayout.defaultsDictionary(configuration.uniforms)
    }
}
