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

    @Binding var uniformValues: [String: UniformValue]
    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime

    init(
        configuration: PhosphorConfiguration,
        source: String,
        assets: [String: PhosphorAsset] = [:],
        isPaused: Binding<Bool>? = nil,
        resetSignal: Int = 0,
        displayedResource: ResourceID? = nil,
        uniformValues: Binding<[String: UniformValue]>
    ) {
        self.configuration = configuration
        self.source = source
        self.assets = assets
        self.isPausedExternally = isPaused
        self.resetSignal = resetSignal
        self.displayedResource = displayedResource
        self._uniformValues = uniformValues
    }

    init(
        parsed: ParsedPhosphorSource,
        assets: [String: PhosphorAsset] = [:],
        isPaused: Binding<Bool>? = nil,
        resetSignal: Int = 0,
        displayedResource: ResourceID? = nil,
        uniformValues: Binding<[String: UniformValue]>
    ) {
        self.init(
            configuration: parsed.configuration,
            source: parsed.body,
            assets: assets,
            isPaused: isPaused,
            resetSignal: resetSignal,
            displayedResource: displayedResource,
            uniformValues: uniformValues
        )
    }

    var body: some View {
        PhosphorRunningView(
            runtime: runtime,
            configuration: configuration,
            isPausedExternally: isPausedExternally,
            resetSignal: resetSignal,
            displayedResource: displayedResource,
            uniformValues: uniformValues
        )
    }
}
