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
    let onTextChange: () -> Void
    let isUntouchedTemplate: Bool

    @State private var model = EditorModel()
    @State private var showHeader: Bool = false
    @SceneStorage("phosphor.ui.inspectorTab") private var inspectorTab: InspectorTab = .output
    @SceneStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @SceneStorage("phosphor.ui.showFrameTiming") private var showFrameTiming: Bool = true
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false
    @SceneStorage("phosphor.ui.showInspector") private var showInspector: Bool = false
    @SceneStorage("phosphor.ui.layoutMode") private var layoutMode: LayoutMode = .horizontal
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @Environment(\.textMutator) private var textMutator

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
            text: $text,
            parsed: parsed,
            onTextChange: onTextChange
        )
        .environment(model)
        .onChange(of: parsed.configuration) { _, newConfiguration in
            model.seedUniformDefaults(for: newConfiguration)
        }
        .task {
            model.seedUniformDefaults(for: parsed.configuration)
        }
        .focusedSceneValue(\.shaderText, $text)
        .focusedSceneValue(\.shaderTextMutator, textMutator)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    layoutMode.cycle()
                } label: {
                    Label("Layout", systemImage: layoutMode.systemImage)
                }
                .help(layoutMode.nextLayoutHelp)
            }
            ToolbarItem(placement: .principal) {
                ResourcePickerView(
                    configuration: parsed.configuration,
                    displayedResource: $model.displayedResource
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
                    .frame(minWidth: 480, minHeight: 360)
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
                Toggle(isOn: $showFrameTiming) {
                    Label("Frame Timing", systemImage: "gauge.with.needle")
                }
                .toggleStyle(.button)
                .help("Show or hide the FPS / frame-timing overlay")
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
                    model.isPaused.toggle()
                } label: {
                    Label(
                        model.isPaused ? "Play" : "Pause",
                        systemImage: model.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(model.isPaused ? "Resume" : "Pause time")
            }
            ToolbarItem(placement: .principal) {
                Button {
                    model.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Reset time to 0 and reseed feedback shaders")
            }
            ToolbarItem(placement: .principal) {
                Button {
                    inspectorTab = .generate
                    showInspector = true
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Open the AI generation panel in the inspector")
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
        .inspector(isPresented: $showInspector) {
            PhosphorInspectorView(
                parsed: parsed,
                text: $text,
                isUntouchedTemplate: isUntouchedTemplate,
                onTextChange: onTextChange,
                selection: $inspectorTab,
                onGeneratingChange: { generating in
                    // Keep the inspector + Generate tab visible while a
                    // generation is in flight so progress is obvious.
                    if generating {
                        inspectorTab = .generate
                        showInspector = true
                    }
                }
            )
            .inspectorColumnWidth(min: 360, ideal: 480, max: 900)
        }
    }
}
