import PhosphorSupport
import SwiftUI
import Metal

/// Top-level view for a flat `.metal` document. Hands off to
/// ``PhosphorEditorBody`` so the bundle-document variant can share the
/// same UI.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var runtime: PhosphorRuntime?
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @AppStorage("phosphor.ui.showInspector") private var showInspector: Bool = false

    var body: some View {
        PhosphorEditorBody(
            text: $document.text,
            parsed: document.parsed,
            assets: [:],
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate,
            editorAccessory: { EmptyView() }
        )
        .environment(runtime)
        .task(id: RuntimeKey(parsed: document.parsed, assetNames: [])) {
            await reloadRuntime(parsed: document.parsed, assets: [:])
        }
        .inspector(isPresented: $showInspector) {
            PhosphorInspector(parsed: document.parsed, runtime: runtime)
        }
    }

    @MainActor
    private func reloadRuntime(parsed: ParsedPhosphorSource, assets: [String: PhosphorAsset]) {
        guard let environment = parsed.environment else {
            runtime = nil
            return
        }
        do {
            if let runtime {
                try runtime.update(environment: environment, source: parsed.body, assets: assets)
            } else {
                guard let device = MTLCreateSystemDefaultDevice() else { return }
                let newRuntime = try PhosphorRuntime(
                    device: device, environment: environment, source: parsed.body, assets: assets
                )
                newRuntime.audioCapture = audioCapture
                runtime = newRuntime
            }
        } catch {
            print("PhosphorDocumentView: runtime reload failed: \(error)")
        }
    }
}

/// Composite key used by `.task(id:)` so runtime reloads retrigger when
/// the parsed source or set of asset names changes.
private struct RuntimeKey: Hashable {
    var parsed: ParsedPhosphorSource
    var assetNames: Set<String>
}
