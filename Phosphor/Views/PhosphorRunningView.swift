import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// Gates the render surface on a non-degenerate view size and tracks that
/// size for point-to-pixel mouse conversion. The diagnostics + uniforms
/// panels are overlaid one level up, in ``ShaderEditorLayoutView``.
struct PhosphorRunningView: View {
    let configuration: PhosphorConfiguration

    /// Logical view size (in points). Combined with the drawable size to
    /// convert mouse coordinates from points to pixels.
    @State private var viewSize: CGSize = .zero

    var body: some View {
        // Only mount the render surface (and its MTKView) once we have a
        // non-degenerate size. During the window-sizing race at document load
        // the view briefly reports zero width/height; instantiating a Metal
        // drawable at that size crashes (nextDrawable returns nil).
        Group {
            if viewSize.width > 0, viewSize.height > 0 {
                PhosphorRenderSurfaceView(configuration: configuration, viewSize: viewSize)
            } else {
                Color.black
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
            viewSize = newSize
        }
    }
}
