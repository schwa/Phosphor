import PhosphorSupport
import SwiftUI
import UniformTypeIdentifiers

/// Chat-style generation panel hosted in the inspector's "Generate" tab.
///
/// A scrollable transcript of prompts and responses sits at the top; the
/// compose area (prompt field, model picker, Generate button) is pinned at
/// the bottom. Each generation runs ``ShaderGenerator`` and replaces the
/// document's text on success.
///
/// Non-modal: the user can iterate while watching the live preview. Reports
/// generation start/stop via ``onGeneratingChange`` so the host can keep the
/// inspector open.
struct GeneratePanel: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let isUntouchedTemplate: Bool
    let onTextChange: () -> Void
    /// Stable key for persisting this transcript to disk (#99). nil disables
    /// persistence (e.g. previews, unsaved docs with no identity).
    var logIdentity: String?
    var onGeneratingChange: (Bool) -> Void = { _ in }

    @Environment(\.textMutator) private var textMutator

    @State private var prompt: String = ""
    @State private var isGenerating: Bool = false
    @State private var status: GenerationStatus?
    @State private var turns: [GenerationTurn] = []
    /// Source identity we last seeded the transcript from, so re-hydration
    /// only happens when the document actually changes underneath us (e.g.
    /// switching shaders in a bundle), not on every keystroke.
    @State private var seededFromSource: String?
    @FocusState private var promptFocused: Bool
    @AppStorage("phosphor.generation.model") private var modelRawValue: String = GenerationModel.onDevice.rawValue
    /// Planning mode (#74): when on, a plan turn runs before codegen. Off by
    /// default (it adds a second model turn / latency); persisted.
    @AppStorage("phosphor.generation.planFirst") private var planFirst: Bool = false
    @State private var showExporter = false

    private var selectedModel: GenerationModel {
        GenerationModel(rawValue: modelRawValue) ?? .onDevice
    }

    private var isModifying: Bool {
        parsed.hasFrontMatter && !isUntouchedTemplate
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .onAppear {
            hydrateIfNeeded()
            promptFocused = true
        }
        .onChange(of: text) { _, _ in hydrateIfNeeded() }
        .onChange(of: turns) { _, newTurns in
            if let logIdentity {
                GenerationLogStore.save(identity: logIdentity, turns: newTurns)
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(turns) { turn in
                    TurnRow(turn: turn)
                        .id(turn.id)
                        .listRowSeparator(.hidden)
                }
                if isGenerating {
                    statusRow
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay {
                if turns.isEmpty, !isGenerating {
                    ContentUnavailableView {
                        Label("Generate a Shader", systemImage: "sparkles")
                    } description: {
                        Text(isModifying
                                ? "Describe how to change the current shader, e.g. \"make it pulse with the time\"."
                                : "Describe the effect you want, e.g. \"a swirling galaxy\".")
                    }
                }
            }
            .onChange(of: turns.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isGenerating) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private var statusRow: some View {
        let status = status ?? .generating(attempt: 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("status")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = isGenerating ? "status" : turns.last.map { AnyHashable($0.id) }
        guard let target else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(isModifying ? "Describe a change…" : "Describe a shader…", text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .disabled(isGenerating)
                .focused($promptFocused)
                .onSubmit(submit)

            HStack {
                Picker("Model", selection: $modelRawValue) {
                    ForEach(GenerationModel.all, id: \.rawValue) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(isGenerating)

                Toggle("Plan first", isOn: $planFirst)
                    .toggleStyle(.checkbox)
                    .disabled(isGenerating)
                    .help("Run a planning step before generating. More deliberate, but slower (an extra model turn).")

                Button("Export Transcript", systemImage: "square.and.arrow.up") {
                    showExporter = true
                }
                .labelStyle(.iconOnly)
                .help("Export this transcript as JSON")
                .disabled(turns.isEmpty)

                Spacer()

                Button {
                    submit()
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(isModifying ? "Modify" : "Generate", systemImage: "sparkles")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(12)
        .background(.background.secondary)
        .fileExporter(
            isPresented: $showExporter,
            document: TranscriptDocument(log: GenerationLog(identity: logIdentity ?? "transcript", turns: turns)),
            contentType: .json,
            defaultFilename: "Transcript"
        ) { _ in }
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await generate() }
    }

    // MARK: - Generation

    private func generate() async {
        let submitted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let modifying = isModifying
        let sentSource = modifying ? text : ""
        let sentBytes = sentSource.utf8.count
        turns.append(.user(submitted))
        prompt = ""
        isGenerating = true
        onGeneratingChange(true)
        status = .generating(attempt: 1, isModifying: modifying, sourceByteCount: sentBytes)
        defer {
            isGenerating = false
            onGeneratingChange(false)
            status = nil
            promptFocused = true
        }

        let started = ContinuousClock.now
        do {
            let adapter = try FoundationModelAdapter.make(model: selectedModel)
            let result = try await ShaderGenerator(model: adapter).generate(
                prompt: submitted,
                existingSource: sentSource,
                plan: planFirst
            ) { phase in
                status = GenerationStatus(phase: phase, isModifying: modifying, sourceByteCount: sentBytes)
                // A failed attempt (and the plan) becomes its OWN transcript
                // turn, so the user sees each step as a separate message
                // rather than one turn that gets replaced.
                switch phase {
                case .retrying(let compileError):
                    turns.append(.retried(compileError, kind: .compile))

                case .retryingMalformed(let decodeError):
                    turns.append(.retried(decodeError, kind: .malformed))

                case .planned(let plan):
                    turns.append(.plan(intent: plan.intent, shape: plan.shape.displayName, body: plan.plan))

                case .generating, .planning:
                    break
                }
            }
            let elapsed = started.duration(to: .now)
            if let textMutator {
                textMutator.apply(result.source, actionName: modifying ? "Modify Shader" : "Generate Shader")
            } else {
                text = result.source
                onTextChange()
            }
            // We just wrote the source ourselves; record what we expect so the
            // text onChange doesn't re-hydrate and wipe the transcript.
            seededFromSource = result.source
            let verb = modifying ? "Modified shader" : "Generated shader"
            turns.append(.assistant(
                title: result.title,
                summary: "\(verb) in \(Self.formatted(elapsed))"
            ))
        } catch {
            let elapsed = started.duration(to: .now)
            turns.append(.error("\(error)\n\nFailed after \(Self.formatted(elapsed))"))
        }
    }

    // MARK: - Hydration

    /// Seed the transcript from prompts embedded in the source the first time
    /// we see a given document, and whenever the source changes to one we
    /// didn't write ourselves (e.g. switching shaders in a bundle). Responses
    /// aren't persisted, so re-hydrated turns are user prompts only.
    /// Human-readable elapsed time, e.g. "0.8s" or "1m 12s".
    private static func formatted(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }

    private func hydrateIfNeeded() {
        guard seededFromSource != text else { return }
        seededFromSource = text
        // Prefer the persisted JSON log (full history incl. responses); fall
        // back to user prompts embedded in the source (#99).
        if let logIdentity, let log = GenerationLogStore.load(identity: logIdentity), !log.turns.isEmpty {
            turns = log.turns
        } else {
            turns = PromptHistory.extract(from: text).map { .user($0) }
        }
    }
}

/// One transcript row, styled per role.
private struct TurnRow: View {
    let turn: GenerationTurn

    var body: some View {
        // Make all transcript text selectable/copyable (#95). The composer's
        // interactive controls live elsewhere, so this only affects Text.
        rowContent.textSelection(.enabled)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch turn.role {
        case .user:
            bubble(
                alignment: .trailing,
                background: Color.accentColor.opacity(0.18),
                content: Text(turn.text)
            )

        case .plan(let intent, let shape):
            bubble(
                alignment: .leading,
                background: Color.blue.opacity(0.10),
                content: VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label(intent, systemImage: "list.clipboard")
                            .font(.callout.weight(.medium))
                        Text(shape)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: .capsule)
                    }
                    Text(turn.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            )

        case .assistant(let title):
            bubble(
                alignment: .leading,
                background: Color.secondary.opacity(0.12),
                content: VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                    Text(turn.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            )

        case .retried(let kind):
            bubble(
                alignment: .leading,
                background: Color.orange.opacity(0.14),
                content: VStack(alignment: .leading, spacing: 4) {
                    Label(retryHeadline(kind), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    Text(turn.text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            )

        case .error:
            bubble(
                alignment: .leading,
                background: Color.red.opacity(0.12),
                content: Label(turn.text, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            )
        }
    }

    private func retryHeadline(_ kind: GenerationTurn.RetryKind) -> String {
        switch kind {
        case .compile: "Didn’t compile — retrying with the errors"
        case .malformed: "Malformed response — asking for a complete one"
        }
    }

    private func bubble(alignment: HorizontalAlignment, background: Color, content: some View) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            content
                .padding(10)
                .background(background, in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }
}

#Preview("Empty") {
    GeneratePanel(
        text: .constant(""),
        parsed: ParsedPhosphorSource(source: ""),
        isUntouchedTemplate: true
    ) {}
    .frame(width: 420, height: 600)
}

#Preview("Modify") {
    GeneratePanel(
        text: .constant("/* prompt: a swirling galaxy */\n// existing kernel\nkernel void image() {}"),
        parsed: ParsedPhosphorSource(source: ""),
        isUntouchedTemplate: false
    ) {}
    .frame(width: 420, height: 600)
}
