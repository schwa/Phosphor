import PhosphorSupport
import SwiftUI

/// Doc-agnostic shader editor: split-pane source / preview, with toolbar.
///
/// Takes plain bindings and values so it can be hosted by either
/// ``PhosphorDocumentView`` (flat `.metal`) or
/// ``PhosphorBundleDocumentView`` (`.phosphor` package). All persistence
/// concerns stay with the wrapping per-doc view.
struct ShaderEditorView: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    let onTextChange: () -> Void
    let isUntouchedTemplate: Bool

    @State private var showHeader: Bool = false
    @State private var showGenerate: Bool = false
    @State private var isPaused: Bool = false
    @State private var resetSignal: Int = 0
    /// Which resource the preview blits to the drawable. `nil` falls back
    /// to the configuration's declared output (the normal case).
    @State private var displayedResource: ResourceID?
    /// Live user-uniform values, shared between the render surface and the
    /// uniforms panel. Seeded from the configuration's declared defaults.
    @State private var uniformValues: [String: UniformValue] = [:]
    @SceneStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false
    @SceneStorage("phosphor.ui.showInspector") private var showInspector: Bool = false
    @SceneStorage("phosphor.ui.layoutMode") private var layoutMode: LayoutMode = .sideBySide
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?

    /// True if the current document has at least one declared uniform.
    private var hasUniforms: Bool {
        !parsed.configuration.uniforms.isEmpty
    }

    /// Two-way binding for the mic toggle: writes the AppStorage flag AND
    /// pushes through to the live engine.
    private var micToggleBinding: Binding<Bool> {
        Binding(
            get: { micEnabled },
            set: { newValue in
                micEnabled = newValue
                audioCapture?.isEnabled = newValue
            }
        )
    }

    var body: some View {
        ShaderEditorLayoutView(
            layoutMode: layoutMode,
            text: $text,
            parsed: parsed,
            assets: assets,
            onTextChange: onTextChange,
            isPaused: $isPaused,
            resetSignal: resetSignal,
            displayedResource: displayedResource,
            uniformValues: $uniformValues,
            showUniformsPanel: showUniformsPanel,
            frontMatterDiagnostics: parsed.diagnostics
        )
        .onChange(of: parsed.configuration) { _, newConfiguration in
            uniformValues = UserUniformsLayout.defaultsDictionary(newConfiguration.uniforms)
        }
        .task {
            uniformValues = UserUniformsLayout.defaultsDictionary(parsed.configuration.uniforms)
        }
        .focusedSceneValue(\.shaderText, $text)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    layoutMode.toggle()
                } label: {
                    Label(
                        layoutMode == .sideBySide ? "Overlay Layout" : "Side-by-Side Layout",
                        systemImage: layoutMode == .sideBySide ? "rectangle.on.rectangle" : "rectangle.split.2x1"
                    )
                }
                .help(layoutMode == .sideBySide ? "Switch to overlay layout" : "Switch to side-by-side layout")
            }
            ToolbarItem(placement: .principal) {
                ResourcePickerView(
                    configuration: parsed.configuration,
                    displayedResource: $displayedResource
                )
            }
            ToolbarItem(placement: .principal) {
                Button {
                    showHeader.toggle()
                } label: {
                    Label("Phosphor.h", systemImage: "doc.text.magnifyingglass")
                }
                .popover(isPresented: $showHeader, arrowEdge: .top) {
                    ScrollView([.horizontal, .vertical]) {
                        MetalSourceView(text: PhosphorHeader.source(for: parsed.configuration))
                            .padding(12)
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Toggle(isOn: $showUniformsPanel) {
                    Label("Uniforms", systemImage: "slider.horizontal.3")
                }
                .toggleStyle(.button)
                .disabled(!hasUniforms)
                .help(hasUniforms
                    ? "Show or hide the uniforms panel"
                    : "No uniforms declared in this shader")
            }
            ToolbarItem(placement: .principal) {
                Toggle(isOn: micToggleBinding) {
                    Label("Microphone", systemImage: micEnabled ? "mic.fill" : "mic.slash")
                }
                .toggleStyle(.button)
                .disabled(audioCapture?.isPermissionDenied ?? false)
                .help(audioCapture?.isPermissionDenied == true
                    ? "Microphone access was denied. Enable it in System Settings → Privacy & Security."
                    : "Enable microphone input for audio-reactive shaders")
            }
            ToolbarItem(placement: .principal) {
                Button {
                    isPaused.toggle()
                } label: {
                    Label(
                        isPaused ? "Play" : "Pause",
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(isPaused ? "Resume" : "Pause time")
            }
            ToolbarItem(placement: .principal) {
                Button {
                    resetSignal &+= 1
                    isPaused = false
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Reset time to 0 and reseed feedback shaders")
            }
            ToolbarItem(placement: .principal) {
                Button {
                    showGenerate = true
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Toggle inspector panel")
            }
        }
        .sheet(isPresented: $showGenerate) {
            GeneratePanel(
                isPresented: $showGenerate,
                text: $text,
                parsed: parsed,
                isUntouchedTemplate: isUntouchedTemplate,
                onTextChange: onTextChange
            )
        }
    }
}
