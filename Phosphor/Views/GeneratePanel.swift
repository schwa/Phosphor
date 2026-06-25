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
/// A persistent ``ConversationStore`` drives an agentic model session: the
/// model edits the live `.metal` source through tools (edit body, read/write
/// configuration, compile) while assistant prose and tool calls stream into the
/// transcript in real time. The editor and preview update *during* the turn as
/// the model edits.
///
/// Conversational mode needs a backend with reliable tool calling (Anthropic or
/// OpenAI); the composer surfaces a clear message when no credentials are
/// configured.
struct GeneratePanel: View {
    let parsed: ParsedPhosphorSource
    /// The persistent conversation store, owned by the editor view so chat
    /// history survives inspector tab switches. `nil` until created.
    let store: ConversationStore?
    var onGeneratingChange: (Bool) -> Void = { _ in }

    @Environment(CredentialsModel.self) private var credentials
    @AppStorage("phosphor.modelProvider") private var backend: GenerationBackend = .claudeSubscription
    @State private var prompt: String = ""
    @State private var exportItem: ConversationExport?
    @State private var showExporter = false
    @FocusState private var promptFocused: Bool

    private var hasCredentials: Bool { credentials.hasCredentials }

    var body: some View {
        VStack(spacing: 0) {
            if hasCredentials {
                transcript
                Divider()
                composer
            } else {
                missingCredentials
            }
        }
        .onAppear {
            promptFocused = true
        }
        // Publish the export action so the File menu can trigger it. nil when
        // there's no conversation store yet (disables the menu item).
        .focusedSceneValue(\.exportDebugLog, store == nil ? nil : ExportDebugLogAction(run: exportDebugInfo))
        .onChange(of: store?.isGenerating ?? false) { _, generating in
            onGeneratingChange(generating)
        }
    }

    // MARK: - Missing credentials

    /// Shown in place of the whole panel when the selected provider has no
    /// stored credentials.
    private var missingCredentials: some View {
        ContentUnavailableView {
            Label("Sign in to Generate", systemImage: "key.horizontal")
        } description: {
            Text("Shader generation needs credentials for the selected provider. Add an API key or sign in under Settings → Models.")
        } actions: {
            #if os(macOS)
            SettingsLink {
                Text("Open Settings…")
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .listRowSeparator(.hidden)
                }
                // Stable sentinel at the very bottom; always the scroll target
                // so streaming content (which changes row ids/heights) still
                // pins to the end.
                HStack {
                    Spacer()
                    Image(systemName: "sparkle")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .id(Self.bottomID)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .onChange(of: store?.items.count ?? 0) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store?.isGenerating ?? false) { _, _ in scrollToEnd(proxy) }
            // Streamed prose grows the last item without changing the count;
            // track its content length so we keep pinned to the bottom.
            .onChange(of: lastItemContentLength) { _, _ in scrollToEnd(proxy) }
        }
    }

    /// A signal that grows as the last transcript item's content streams in,
    /// used to keep the view scrolled to the bottom during a turn.
    private var lastItemContentLength: Int {
        guard let last = store?.items.last else { return 0 }
        switch last.kind {
        case .user(let text), .assistant(let text), .error(let text):
            return text.count

        case .tool(_, _, let result, _):
            return result?.count ?? 0
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store?.isEmpty ?? true, store?.isGenerating != true {
            ContentUnavailableView {
                Label("Generate a Shader", systemImage: "sparkles")
            } description: {
                Text("Describe an effect, e.g. “a swirling galaxy”. The model edits the shader and compiles it as you watch.")
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

    private static let bottomID = "phosphor.chat.bottom"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text("\(backend.displayName) · \(ConversationProvider.selectedModelID(for: backend))")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            promptField
        }
        .padding(12)
        .background(.background.secondary)
        .fileExporter(
            isPresented: $showExporter,
            item: exportItem,
            defaultFilename: "Phosphor-Session-\(Self.timestamp())"
        ) { _ in }
    }

    /// The prompt input and its inline action buttons, wrapped in an
    /// Xcode-style glowing multicolor border that brightens on focus.
    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Describe a shader or a change…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(5...10)
                .foregroundStyle(.primary)
                .disabled(isGenerating)
                .focused($promptFocused)
                // Enter sends; Shift+Enter inserts a newline. We insert the
                // newline ourselves because returning `.ignored` doesn't
                // reliably forward the keystroke to the field.
                .onKeyPress(keys: [.return]) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        prompt += "\n"
                        return .handled
                    }
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
                .buttonStyle(.borderless)
                .help("Export the full session (raw transcript, system prompt, tool calls/results, usage, current source) as JSON for debugging.")

                Spacer()
                if isGenerating {
                    StopButton { store?.stop() }
                        .help("Stop the current generation.")
                } else {
                    Button("Send", systemImage: "arrow.up") {
                        submit()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .clipShape(.circle)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                }
            }
        }
        .padding(12)
        .glowingPromptBorder(cornerRadius: 16, active: promptFocused)
    }

    private func exportDebugInfo() {
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
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating && hasCredentials
    }

    private func submit() {
        guard canSubmit else { return }
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

    /// How long this item took to produce, e.g. "1.2s". Empty when unknown
    /// (still in flight, or a user prompt).
    @ViewBuilder
    private var durationLabel: some View {
        if let duration = item.duration {
            Text(Self.durationText(duration))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        return String(format: "%.1fs", seconds)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.isEmpty ? "…" : text)
                        .fixedSize(horizontal: false, vertical: true)
                    durationLabel
                }
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
                } else {
                    durationLabel
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
        case "readConfiguration", "read": return true
        default: return false
        }
    }

    private func icon(for name: String) -> String {
        switch name {
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil"
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
