import Foundation
import MetalSprockets
import MetalSprocketsUI
import SwiftUI

/// The body when the runtime is live. Owns playback-clock and mouse-input
/// state, drives the render surface, and layers the diagnostics + uniforms
/// panels on top of it.
struct PhosphorRunningView: View {
    let runtime: PhosphorRuntime
    let environment: PhosphorEnvironment
    let frontMatterDiagnostics: [PhosphorDiagnostic]
    let isPausedExternally: Binding<Bool>?
    let resetSignal: Int
    let displayedResource: ResourceID?
    @Binding var uniformValues: [String: UniformValue]
    let showUniformsPanel: Bool

    /// Reference wall-clock time used as t=0 (subtracted from the
    /// renderer's time to get the kernel's time). Updated on reset.
    @State private var timeBase: Float = 0
    /// Reference frame index.
    @State private var frameBase: UInt32 = 0
    /// Snapshot of (time, frame) emitted while paused. Captured from the
    /// renderer the moment the user pauses.
    @State private var pausedSnapshot: (time: Float, frame: Float)?
    /// On the next frame, pull a fresh snapshot from the live values.
    @State private var capturePauseSnapshot: Bool = false
    /// On the next frame, set timeBase/frameBase = live values.
    @State private var rebaseRequested: Bool = false

    // Mouse state, in pixel coordinates (matching uniforms.resolution).
    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero
    /// Logical view size (in points). Combined with the drawable size to
    /// convert mouse coordinates from points to pixels.
    @State private var viewSize: CGSize = .zero

    var body: some View {
        // Only mount the render surface (and its MTKView) once we have a
        // non-degenerate size. During the window-sizing race at document load
        // the view briefly reports zero width/height; instantiating a Metal
        // drawable at that size crashes (nextDrawable returns nil).
        //
        // The panels are stacked ABOVE the render surface so they receive
        // clicks/drags first — the surface uses a greedy
        // DragGesture(minimumDistance: 0) for mouse tracking that would
        // otherwise swallow control interactions.
        ZStack(alignment: .bottom) {
            if viewSize.width > 0, viewSize.height > 0 {
                PhosphorRenderSurfaceView(
                    runtime: runtime,
                    environment: environment,
                    uniformValues: uniformValues,
                    displayedResource: displayedResource,
                    isPausedExternally: isPausedExternally,
                    resetSignal: resetSignal,
                    viewSize: viewSize,
                    mousePosition: $mousePosition,
                    mouseButtons: $mouseButtons,
                    mouseClickOrigin: $mouseClickOrigin,
                    timeBase: $timeBase,
                    frameBase: $frameBase,
                    pausedSnapshot: $pausedSnapshot,
                    capturePauseSnapshot: $capturePauseSnapshot,
                    rebaseRequested: $rebaseRequested
                )
            }

            DiagnosticsView(diagnostics: frontMatterDiagnostics + runtime.diagnostics)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)

            UniformsPanelView(
                uniforms: environment.uniforms,
                showPanel: showUniformsPanel,
                uniformValues: $uniformValues
            )
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
            viewSize = newSize
        }
    }
}
