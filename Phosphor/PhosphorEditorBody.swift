import PhosphorSupport
import SwiftUI

/// Doc-agnostic editor body: split-pane source / preview, with toolbar.
///
/// Takes plain bindings and values so it can be hosted by either
/// ``PhosphorDocumentView`` (flat `.metal`) or
/// ``PhosphorBundleDocumentView`` (`.phosphor` package). All persistence
/// concerns stay with the wrapping per-doc view.
struct PhosphorEditorBody: View {
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
    /// to the environment's declared output (the normal case).
    @State private var displayedResource: ResourceID?
    @AppStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false
    @AppStorage("phosphor.ui.showInspector") private var showInspector: Bool = false
    @SceneStorage("phosphor.ui.layoutMode") private var layoutMode: LayoutMode = .sideBySide
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?

    /// True if the current document has at least one declared uniform.
    private var hasUniforms: Bool {
        !(parsed.environment?.uniforms.isEmpty ?? true)
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
        Group {
            switch layoutMode {
            case .sideBySide:
                sideBySideLayout
            case .overlay:
                overlayLayout
            }
        }
        .frame(minWidth: 800, minHeight: 500)
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
                ResourcePicker(
                    environment: parsed.environment,
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
                    HeaderPopover(environment: parsed.environment ?? PhosphorEnvironment(output: "image"))
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
            .frame(minWidth: 480, minHeight: 240)
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private var sideBySideLayout: some View {
        HSplitView {
            CodePane(text: $text, onTextChange: onTextChange)
                .frame(minWidth: 280)
            PreviewPane(
                parsed: parsed,
                assets: assets,
                isPaused: $isPaused,
                resetSignal: resetSignal,
                displayedResource: displayedResource
            )
            .frame(minWidth: 360)
        }
    }

    @ViewBuilder
    private var overlayLayout: some View {
        ZStack {
            PreviewPane(
                parsed: parsed,
                assets: assets,
                isPaused: $isPaused,
                resetSignal: resetSignal,
                displayedResource: displayedResource
            )
            .ignoresSafeArea()

            CodePane(text: $text, onTextChange: onTextChange, opaque: false)
        }
    }
}

/// User-facing layout mode for the editor: side-by-side splitter
/// (default) or code panel overlaid on a full-bleed preview.
enum LayoutMode: String, CaseIterable {
    case sideBySide
    case overlay

    mutating func toggle() {
        self = self == .sideBySide ? .overlay : .sideBySide
    }
}

/// Left side of the document split: the editable Metal source.
private struct CodePane: View {
    @Binding var text: String
    let onTextChange: () -> Void
    /// When true (the default), paints an opaque text-background color
    /// behind the editor. Overlay layout passes `false` so the panel's
    /// material background shows through.
    var opaque: Bool = true

    var body: some View {
        MetalSourceView(text: $text)
            .background(opaque ? Color(.textBackgroundColor) : .clear)
            .onChange(of: text) { _, _ in
                onTextChange()
            }
    }
}

/// Dropdown that lets the user pick which resource the preview should
/// blit to the drawable. "Output" (nil) follows the environment's declared
/// output; other choices are individual texture resources. Disabled when
/// the environment has only one resource (or none).
private struct ResourcePicker: View {
    let environment: PhosphorEnvironment?
    @Binding var displayedResource: ResourceID?

    private var resourceIDs: [ResourceID] {
        environment?.textures.map(\.id) ?? []
    }

    private var isDisabled: Bool {
        resourceIDs.count < 2
    }

    var body: some View {
        Picker("Preview", selection: $displayedResource) {
            Text("Output (\(environment?.output.raw ?? "—"))").tag(ResourceID?.none)
            Divider()
            ForEach(resourceIDs, id: \.self) { id in
                Text(id.raw).tag(Optional(id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 180)
        .disabled(isDisabled)
        .help(isDisabled
            ? "Only one resource declared—nothing to switch to"
            : "Preview a specific resource instead of the declared output")
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
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// Right side of the document split: either the live render or a
/// no-front-matter placeholder.
private struct PreviewPane: View {
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    @Binding var isPaused: Bool
    let resetSignal: Int
    let displayedResource: ResourceID?

    var body: some View {
        if let view = PhosphorView(
            parsed: parsed,
            assets: assets,
            isPaused: $isPaused,
            resetSignal: resetSignal,
            displayedResource: displayedResource
        ) {
            view
        } else {
            NoFrontMatterPlaceholder(diagnostics: parsed.diagnostics)
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

#Preview("No front-matter placeholder") {
    NoFrontMatterPlaceholder(diagnostics: [])
        .frame(width: 400, height: 300)
}

#Preview("Header popover") {
    HeaderPopover(environment: PhosphorEnvironment(output: "image"))
}
