import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
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
    /// Stable key for persisting the generation transcript (#99).
    var logIdentity: String?

    @State private var model = EditorModel()
    /// The conversational generation session. Owned here (not in
    /// ``GeneratePanel``) so the chat history survives inspector tab switches,
    /// which tear down the non-selected tab's view tree.
    @State private var conversation: ConversationStore?
    @State private var showHeader: Bool = false
    @SceneStorage("phosphor.ui.inspectorTab") private var inspectorTab: InspectorTab = .generate
    @SceneStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @SceneStorage("phosphor.ui.showFrameTiming") private var showFrameTiming: Bool = true
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false
    @SceneStorage("phosphor.ui.showInspector") private var showInspector: Bool = true
    @SceneStorage("phosphor.ui.layoutMode") private var layoutMode: LayoutMode = .horizontal
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime
    @Environment(\.textMutator) private var textMutator

    /// True if the current document has at least one declared uniform.
    private var hasUniforms: Bool {
        !parsed.configuration.uniforms.isEmpty
    }

    /// Lazily creates the per-document conversation store, wiring it to the
    /// live text binding and the undoable text mutator.
    private func ensureConversation() {
        guard conversation == nil else { return }
        conversation = ConversationStore(
            device: runtime.device,
            readSource: { text },
            writeSource: { newText, actionName in
                if let textMutator {
                    textMutator.apply(newText, actionName: actionName)
                } else {
                    text = newText
                    onTextChange()
                }
            }
        )
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
            ensureConversation()
        }
        .focusedSceneValue(\.shaderText, $text)
        .focusedSceneValue(\.shaderTextMutator, textMutator)
        .focusedSceneValue(\.editorCommandState, EditorCommandState(
            model: model,
            layoutMode: $layoutMode,
            showUniformsPanel: $showUniformsPanel,
            showFrameTiming: $showFrameTiming,
            showInspector: $showInspector,
            hasUniforms: hasUniforms,
            showGenerate: {
                inspectorTab = .generate
                showInspector = true
            }
        ))
        .toolbarRole(.editor)
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            PhosphorInspectorView(
                parsed: parsed,
                text: $text,
                isUntouchedTemplate: isUntouchedTemplate,
                onTextChange: onTextChange,
                logIdentity: logIdentity,
                conversation: conversation,
                selection: $inspectorTab
            ) { generating in
                // Keep the inspector + Generate tab visible while a
                // generation is in flight so progress is obvious.
                if generating {
                    inspectorTab = .generate
                    showInspector = true
                }
            }
            .inspectorColumnWidth(min: 360, ideal: 480, max: 900)
        }
    }

    /// The editor toolbar. Grouped by purpose: view controls, transport,
    /// panel toggles, and primary actions.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // View: layout cycle + which resource the preview shows.
        ToolbarItem(placement: .navigation) {
            Picker("Layout", selection: $layoutMode) {
                ForEach(LayoutMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Choose editor layout")
        }
        ToolbarItem(placement: .navigation) {
            Button {
                showHeader.toggle()
            } label: {
                Label("Phosphor.h", systemImage: "doc.text.magnifyingglass")
            }
            .help("View the generated Phosphor.h prelude")
            .popover(isPresented: $showHeader, arrowEdge: .top) {
                ScrollView([.horizontal, .vertical]) {
                    MetalSourceView(text: PhosphorHeader.source(for: parsed.configuration))
                        .padding(12)
                }
                .frame(minWidth: 480, minHeight: 360)
            }
        }
        ToolbarItem(placement: .navigation) {
            ResourcePickerView(
                configuration: parsed.configuration,
                displayedResource: $model.displayedResource
            )
        }

        // Transport: play/pause + reset time.
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

        // Panel toggles.
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $showUniformsPanel) {
                Label("Uniforms", systemImage: "slider.horizontal.3")
            }
            .toggleStyle(.button)
            .disabled(!hasUniforms)
            .help(hasUniforms
                    ? "Show or hide the uniforms panel"
                    : "No uniforms declared in this shader")
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $showFrameTiming) {
                Label("Frame Timing", systemImage: "gauge.with.needle")
            }
            .toggleStyle(.button)
            .help("Show or hide the FPS / frame-timing overlay")
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: micToggleBinding) {
                Label("Microphone", systemImage: micEnabled ? "mic.fill" : "mic.slash")
            }
            .toggleStyle(.button)
            .disabled(audioCapture?.isPermissionDenied ?? false)
            .help(audioCapture?.isPermissionDenied == true
                    ? "Microphone access was denied. Enable it in System Settings → Privacy & Security."
                    : "Enable microphone input for audio-reactive shaders")
        }

        // Primary actions, trailing.
        ToolbarItem(placement: .primaryAction) {
            Button {
                inspectorTab = .generate
                showInspector = true
            } label: {
                Label("Generate", systemImage: "sparkles")
            }
            .help("Open the AI generation panel in the inspector")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle inspector panel")
        }
    }
}
