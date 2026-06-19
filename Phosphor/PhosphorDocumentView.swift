import PhosphorSupport
import SwiftUI

/// Top-level view for an open `.metal` document.
///
/// Same split-pane layout as the demo browser: source on the left, preview
/// on the right. Read-only for now; live editing is a separate feature.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var showHeader: Bool = false
    @State private var showGenerate: Bool = false
    @AppStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false
    @Environment(\.audioCapture) private var audioCapture

    /// True if the current document has at least one declared uniform.
    private var hasUniforms: Bool {
        !(document.parsed.environment?.uniforms.isEmpty ?? true)
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
        HSplitView {
            codePane
                .frame(minWidth: 280, idealWidth: 420)
            previewPane
                .frame(minWidth: 360, idealWidth: 640)
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showHeader.toggle()
                } label: {
                    Label("Phosphor.h", systemImage: "doc.text.magnifyingglass")
                }
                .popover(isPresented: $showHeader, arrowEdge: .top) {
                    headerPopover
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showUniformsPanel) {
                    Label("Uniforms", systemImage: "slider.horizontal.3")
                }
                .toggleStyle(.button)
                .disabled(!hasUniforms)
                .help(hasUniforms
                    ? "Show or hide the uniforms panel"
                    : "No uniforms declared in this shader")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: micToggleBinding) {
                    Label("Microphone", systemImage: micEnabled ? "mic.fill" : "mic.slash")
                }
                .toggleStyle(.button)
                .disabled(audioCapture?.isPermissionDenied ?? false)
                .help(audioCapture?.isPermissionDenied == true
                    ? "Microphone access was denied. Enable it in System Settings → Privacy & Security."
                    : "Enable microphone input for audio-reactive shaders")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showGenerate = true
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $showGenerate) {
            GeneratePanel(isPresented: $showGenerate, document: document)
                .frame(minWidth: 480, minHeight: 240)
        }
    }

    @ViewBuilder
    private var codePane: some View {
        MetalSourceView(text: $document.text)
            .background(Color(.textBackgroundColor))
            .onChange(of: document.text) { _, _ in
                document.refreshParsed()
            }
    }

    @ViewBuilder
    private var headerPopover: some View {
        let env = document.parsed.environment ?? PhosphorEnvironment(output: "image")
        let header = PhosphorHeader.source(for: env)
        ScrollView([.horizontal, .vertical]) {
            MetalSourceView(text: header)
                .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 320, idealHeight: 480)
    }

    @ViewBuilder
    private var previewPane: some View {
        if let view = PhosphorView(parsed: document.parsed) {
            view
        } else {
            ContentUnavailableView {
                Label("No front-matter", systemImage: "doc.text.magnifyingglass")
            } description: {
                if document.parsed.diagnostics.isEmpty {
                    Text("This file has no /* phosphor:environment ... */ block.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Failed to parse front-matter:")
                        ForEach(Array(document.parsed.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(verbatim: String(describing: diagnostic))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

