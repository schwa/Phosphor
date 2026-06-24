import SwiftUI

/// State the View menu needs to drive the active editor's toolbar actions.
/// Published by ``ShaderEditorView`` via `focusedSceneValue` and read by
/// ``ViewCommands``.
@MainActor
struct EditorCommandState {
    var model: EditorModel
    var layoutMode: Binding<LayoutMode>
    var showUniformsPanel: Binding<Bool>
    var showFrameTiming: Binding<Bool>
    var showInspector: Binding<Bool>
    var hasUniforms: Bool
    var showGenerate: () -> Void
}

extension FocusedValues {
    @Entry var editorCommandState: EditorCommandState?
}

/// View-menu additions plus a top-level Preview menu, mirroring the editor
/// toolbar with keyboard shortcuts. All items are disabled when no editor is
/// focused.
struct ViewCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            EditorViewMenu()
        }
        CommandMenu("Render") {
            RenderMenu()
        }
    }
}

/// Items added to the standard View menu: layout, uniforms panel, frame
/// timing, inspector, generate. These are display/layout concerns.
private struct EditorViewMenu: View {
    @FocusedValue(\.editorCommandState) private var state: EditorCommandState?

    var body: some View {
        // Layout (each with its own shortcut).
        Button("Horizontal Split") { state?.layoutMode.wrappedValue = .horizontal }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(state == nil)
        Button("Vertical Split") { state?.layoutMode.wrappedValue = .vertical }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(state == nil)
        Button("Overlay") { state?.layoutMode.wrappedValue = .overlay }
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(state == nil)

        Divider()

        Toggle("Uniforms Panel", isOn: state?.showUniformsPanel ?? .constant(false))
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(state == nil || state?.hasUniforms == false)

        Toggle("Frame Timing", isOn: state?.showFrameTiming ?? .constant(false))
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(state == nil)

        Toggle("Inspector", isOn: state?.showInspector ?? .constant(false))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(state == nil)

        Button("Generate…") {
            state?.showGenerate()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(state == nil)
    }
}

/// Top-level Render menu: controls that change the live render's behavior.
private struct RenderMenu: View {
    @FocusedValue(\.editorCommandState) private var state: EditorCommandState?

    var body: some View {
        Button(state?.model.isPaused == true ? "Resume" : "Pause Time") {
            state?.model.isPaused.toggle()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(state == nil)

        Button("Reset Time") {
            state?.model.reset()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(state == nil)
    }
}
