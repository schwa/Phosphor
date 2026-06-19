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
    @State private var isPaused: Bool = false
    @State private var resetSignal: Int = 0
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
            CodePane(document: document)
                .frame(minWidth: 280, idealWidth: 420)
            PreviewPane(
                document: document,
                isPaused: $isPaused,
                resetSignal: resetSignal
            )
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
                    HeaderPopover(environment: document.parsed.environment ?? PhosphorEnvironment(output: "image"))
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
                    isPaused.toggle()
                } label: {
                    Label(
                        isPaused ? "Play" : "Pause",
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(isPaused ? "Resume" : "Pause time")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    resetSignal &+= 1
                    isPaused = false
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Reset time to 0 and reseed feedback shaders")
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
}

/// Left side of the document split: the editable Metal source.
private struct CodePane: View {
    @Bindable var document: PhosphorMetalDocument

    var body: some View {
        MetalSourceView(text: $document.text)
            .background(Color(.textBackgroundColor))
            .onChange(of: document.text) { _, _ in
                document.refreshParsed()
            }
    }
}

/// Popover that shows the synthesized `Phosphor.h` content for the current
/// document's environment.
private struct HeaderPopover: View {
    let environment: PhosphorEnvironment

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            MetalSourceView(text: PhosphorHeader.source(for: environment))
                .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 320, idealHeight: 480)
    }
}

/// Right side of the document split: either the live render or a
/// no-front-matter placeholder.
private struct PreviewPane: View {
    let document: PhosphorMetalDocument
    @Binding var isPaused: Bool
    let resetSignal: Int

    var body: some View {
        if let view = PhosphorView(
            parsed: document.parsed,
            isPaused: $isPaused,
            resetSignal: resetSignal
        ) {
            view
        } else {
            NoFrontMatterPlaceholder(diagnostics: document.parsed.diagnostics)
        }
    }
}

/// Shown in the preview pane when the source has no parsable front-matter.
private struct NoFrontMatterPlaceholder: View {
    let diagnostics: [PhosphorDiagnostic]

    var body: some View {
        ContentUnavailableView {
            Label("No front-matter", systemImage: "doc.text.magnifyingglass")
        } description: {
            if diagnostics.isEmpty {
                Text("This file has no /* phosphor:environment ... */ block.")
            } else {
                DiagnosticsList(diagnostics: diagnostics)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Vertical list of parse diagnostics, monospaced and text-selectable.
private struct DiagnosticsList: View {
    let diagnostics: [PhosphorDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Failed to parse front-matter:")
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(verbatim: String(describing: diagnostic))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
    }
}

// MARK: - Previews

// Note: `PhosphorDocumentView` itself isn't previewable in isolation —
// `PhosphorMetalDocument` requires a `URLDocumentConfiguration` which the
// document system constructs internally, with no public init available
// outside it. Previews here cover the standalone subviews instead.

#Preview("No front-matter placeholder") {
    NoFrontMatterPlaceholder(diagnostics: [])
        .frame(width: 400, height: 300)
}

#Preview("Header popover") {
    HeaderPopover(environment: PhosphorEnvironment(output: "image"))
}
