import CollaborationKit
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Streaming, conversational generation panel hosted in the inspector's
/// "Generate" tab.
///
/// A persistent ``ConversationStore`` drives an agentic Claude session: the
/// model edits the live `.metal` source through tools (edit body, read/write
/// configuration, compile) while assistant prose and tool calls stream into the
/// transcript in real time. The editor and preview update *during* the turn as
/// the model edits.
///
/// Conversational mode is Claude-only (it needs reliable tool calling); the
/// composer surfaces a clear message when no Anthropic API key is configured.
struct GeneratePanel: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let isUntouchedTemplate: Bool
    let onTextChange: () -> Void
    var logIdentity: String?
    var onGeneratingChange: (Bool) -> Void = { _ in }

    @Environment(\.textMutator) private var textMutator
    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime

    @State private var store: ConversationStore?
    @State private var prompt: String = ""
    @State private var exportItem: ConversationExport?
    @State private var showExporter = false
    /// Cached Keychain check. The Keychain read is expensive and was being run
    /// on every body pass; refresh it on appear and after a Settings change.
    @State private var hasAPIKey: Bool = false
    @FocusState private var promptFocused: Bool

    private func refreshAPIKeyStatus() {
        if case .found(let value) = KeychainStore.readResult(account: KeychainAccount.anthropicAPIKey), !value.isEmpty {
            hasAPIKey = true
        } else {
            hasAPIKey = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .onAppear {
            refreshAPIKeyStatus()
            ensureStore()
            promptFocused = true
        }
        .onChange(of: store?.isGenerating ?? false) { _, generating in
            onGeneratingChange(generating)
        }
    }

    // MARK: - Store

    private func ensureStore() {
        guard store == nil else { return }
        // Read the live binding; write through the undoable TextMutator so each
        // model edit is a single, named undo step.
        store = ConversationStore(
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

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(store?.items ?? []) { item in
                    ConversationRow(item: item)
                        .id(item.id)
                        .listRowSeparator(.hidden)
                }
                if store?.isGenerating == true {
                    thinkingRow
                        .id("thinking")
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .onChange(of: store?.items.count ?? 0) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store?.isGenerating ?? false) { _, _ in scrollToEnd(proxy) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store?.isEmpty ?? true, store?.isGenerating != true {
            ContentUnavailableView {
                Label("Generate a Shader", systemImage: "sparkles")
            } description: {
                Text("Describe an effect, e.g. “a swirling galaxy”. Claude edits the shader and compiles it as you watch.")
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = (store?.isGenerating == true) ? "thinking" : store?.items.last.map { AnyHashable($0.id) }
        guard let target else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hasAPIKey {
                Label("Add an Anthropic API key in Settings → Models to generate.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Describe a shader or a change…", text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .disabled(isGenerating)
                .focused($promptFocused)
                .onKeyPress(keys: [.return]) { keyPress in
                    if keyPress.modifiers.contains(.shift) { return .ignored }
                    submit()
                    return .handled
                }

            HStack {
                if store?.usage.totalTokens ?? 0 > 0 {
                    Label("\(store?.usage.totalTokens ?? 0) tokens", systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }

                Button("Export Debug Info", systemImage: "ladybug") {
                    exportDebugInfo()
                }
                .labelStyle(.iconOnly)
                .help("Export the full session (raw transcript, system prompt, tool calls/results, usage, current source) as JSON for debugging.")

                Spacer()
                if isGenerating {
                    Button("Stop", systemImage: "stop.fill") {
                        store?.stop()
                    }
                    .labelStyle(.iconOnly)
                    .help("Stop the current generation.")
                } else {
                    Button("Send", systemImage: "paperplane") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                }
            }
        }
        .padding(12)
        .background(.background.secondary)
        .fileExporter(
            isPresented: $showExporter,
            item: exportItem,
            defaultFilename: "Phosphor-Session-\(Self.timestamp())"
        ) { _ in }
    }

    private func exportDebugInfo() {
        ensureStore()
        Task {
            guard let store else { return }
            exportItem = await store.buildExport()
            showExporter = true
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private var isGenerating: Bool { store?.isGenerating ?? false }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating && hasAPIKey
    }

    private func submit() {
        guard canSubmit else { return }
        ensureStore()
        let submitted = prompt
        prompt = ""
        store?.send(submitted)
    }
}

/// One transcript row, styled per item kind.
private struct ConversationRow: View {
    let item: ConversationItem

    var body: some View {
        content.textSelection(.enabled)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .user(let text):
            bubble(alignment: .trailing, background: Color.accentColor.opacity(0.18)) {
                Text(text).fixedSize(horizontal: false, vertical: true)
            }

        case .assistant(let text):
            bubble(alignment: .leading, background: Color.secondary.opacity(0.10)) {
                Text(text.isEmpty ? "…" : text)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .tool(let name, let summary, let result, let isError):
            toolRow(name: name, summary: summary, result: result, isError: isError)

        case .error(let message):
            bubble(alignment: .leading, background: Color.red.opacity(0.12)) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toolRow(name: String, summary: String, result: String?, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: name))
                    .foregroundStyle(isError ? .red : .secondary)
                Text(summary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if result == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            if let result, resultWorthShowing(name: name, result: result, isError: isError) {
                Text(result)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.blue).opacity(0.08), in: .rect(cornerRadius: 8))
    }

    /// Only show a tool result when it carries useful detail (errors, compiler
    /// output) — not for "Edit applied." / "Compiles cleanly." noise.
    private func resultWorthShowing(name: String, result: String, isError: Bool) -> Bool {
        if isError { return true }
        switch name {
        case "compileShader": return result.contains("failed")
        case "readConfiguration": return true
        default: return false
        }
    }

    private func icon(for name: String) -> String {
        switch name {
        case "editMetal": return "pencil"
        case "writeConfiguration": return "slider.horizontal.3"
        case "readConfiguration": return "doc.text.magnifyingglass"
        case "compileShader": return "hammer"
        default: return "wrench.and.screwdriver"
        }
    }

    private func bubble(alignment: HorizontalAlignment, background: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            content()
                .padding(10)
                .background(background, in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }
}
