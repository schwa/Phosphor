import Foundation
import Metal
import MetalSprockets
import MetalSprocketsUI
import PhosphorSupport
import SwiftUI

/// SwiftUI surface for a Phosphor 2 effect.
///
/// Owns a ``PhosphorRuntime``, recompiling it whenever `configuration` or
/// `source` change. Drives the render surface with per-frame
/// ``BuiltinUniforms``.
///
/// Renders host controls for each ``UniformDecl`` declared by the configuration
/// (`PhosphorView` keeps a `[String: UniformValue]` of live values, seeded
/// from the declared defaults; each frame the runtime packs them into the
/// user-uniforms buffer).
struct PhosphorView: View {
    let configuration: PhosphorConfiguration
    let source: String
    let frontMatterDiagnostics: [PhosphorDiagnostic]
    /// Host-supplied binary assets keyed by name. Texture resources whose
    /// `initial = "image"` reference these by `name`. Empty for plain
    /// `.metal` documents; populated from the `assets/` directory for
    /// `.phosphor` bundles.
    let assets: [String: PhosphorAsset]
    /// External pause/play state. When `true`, the kernel sees frozen time
    /// and frame values. Optional so existing call sites (and the smoke
    /// tests) keep working without an explicit binding.
    let isPausedExternally: Binding<Bool>?
    /// External reset signal. Each new value triggers a one-shot reset.
    let resetSignal: Int
    /// Resource id to blit to the drawable. `nil` means use the
    /// configuration's declared output. Lets the host preview an
    /// intermediate ping-pong / scratch buffer for debugging.
    let displayedResource: ResourceID?

    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime?
    @State private var uniformValues: [String: UniformValue] = [:]
    @SceneStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true

    init(
        configuration: PhosphorConfiguration,
        source: String,
        assets: [String: PhosphorAsset] = [:],
        isPaused: Binding<Bool>? = nil,
        resetSignal: Int = 0,
        displayedResource: ResourceID? = nil
    ) {
        self.configuration = configuration
        self.source = source
        self.frontMatterDiagnostics = []
        self.assets = assets
        self.isPausedExternally = isPaused
        self.resetSignal = resetSignal
        self.displayedResource = displayedResource
    }

    init?(
        source: String,
        assets: [String: PhosphorAsset] = [:],
        isPaused: Binding<Bool>? = nil,
        resetSignal: Int = 0,
        displayedResource: ResourceID? = nil
    ) {
        self.init(
            parsed: ParsedPhosphorSource(source: source),
            assets: assets,
            isPaused: isPaused,
            resetSignal: resetSignal,
            displayedResource: displayedResource
        )
    }

    init?(
        parsed: ParsedPhosphorSource,
        assets: [String: PhosphorAsset] = [:],
        isPaused: Binding<Bool>? = nil,
        resetSignal: Int = 0,
        displayedResource: ResourceID? = nil
    ) {
        guard let configuration = parsed.configuration else { return nil }
        self.configuration = configuration
        self.source = parsed.body
        self.frontMatterDiagnostics = parsed.diagnostics
        self.assets = assets
        self.isPausedExternally = isPaused
        self.resetSignal = resetSignal
        self.displayedResource = displayedResource
    }

    var body: some View {
        if let runtime {
            PhosphorRunningView(
                runtime: runtime,
                configuration: configuration,
                frontMatterDiagnostics: frontMatterDiagnostics,
                isPausedExternally: isPausedExternally,
                resetSignal: resetSignal,
                displayedResource: displayedResource,
                uniformValues: $uniformValues,
                showUniformsPanel: showUniformsPanel
            )
            .onChange(of: configuration) { _, newConfiguration in
                uniformValues = UserUniformsLayout.defaultsDictionary(newConfiguration.uniforms)
            }
            .task {
                uniformValues = UserUniformsLayout.defaultsDictionary(configuration.uniforms)
            }
        } else {
            // Runtime not ready yet (no parsed config, or first frame hasn't
            // fired). Plain black blends with the rest of the chrome.
            Color.black
        }
    }
}
