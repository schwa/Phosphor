import PhosphorModel
import PhosphorCompile
import PhosphorGeneration
import PhosphorRuntime
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
    /// The single source of truth (#99): one entry per user submission, each
    /// holding its model request/response work + outcome. The displayed
    /// transcript is *derived* from this; nothing display-shaped is stored.
    /// Mirrored to disk only for saved documents.
    @State private var interactions: [Interaction] = []
    /// The user prompt of the interaction currently being generated, if any.
    @State private var inProgressPrompt: String?
    /// Display bubbles emitted live during the in-progress interaction (plan,
    /// retry notices) before it completes and becomes an `Interaction`.
    @State private var inProgressTurns: [GenerationTurn] = []
    /// User prompts re-hydrated from embedded source comments when there's no
    /// persisted log (legacy history). Shown as plain user bubbles.
    @State private var hydratedPrompts: [String] = []
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
    }

    // MARK: - Display projection

    /// The transcript bubbles, *derived* from the source-of-truth
    /// `interactions` (plus any legacy hydrated prompts and the live
    /// in-progress interaction). Nothing display-shaped is stored (#99).
    private var displayTurns: [GenerationTurn] {
        var out: [GenerationTurn] = hydratedPrompts.enumerated().map { index, prompt in
            .user(prompt, id: "hydrated-\(index)")
        }
        for interaction in interactions {
            out.append(contentsOf: Self.turns(for: interaction))
        }
        if let inProgressPrompt {
            out.append(.user(inProgressPrompt, id: "in-progress-prompt"))
            out.append(contentsOf: inProgressTurns)
        }
        return out
    }

    /// Projects one completed interaction into display bubbles: the user
    /// prompt, the plan (if any), one retry bubble per correction, and the
    /// outcome (assistant or error).
    private static func turns(for interaction: Interaction) -> [GenerationTurn] {
        // Derive stable ids from the (stable) interaction id so the projection
        // produces identical identities across body evaluations — otherwise
        // the transcript List rebuilds every row on every render.
        let base = interaction.id.uuidString
        var out: [GenerationTurn] = [.user(interaction.prompt, id: "\(base)-prompt")]
        if let plan = interaction.plan {
            let planElapsed = interaction.exchanges.first { $0.kind == .plan }?.elapsed
            out.append(.plan(intent: plan.planIntent, shape: plan.planShape.displayName, body: plan.planBody, duration: planElapsed, id: "\(base)-plan"))
        }
        // Retries are derived from the exchanges: a retry exchange's request
        // carries the error that triggered it.
        for (index, exchange) in interaction.exchanges.enumerated() {
            switch exchange.kind {
            case .compileRetry: out.append(.retried(exchange.request, kind: .compile, duration: exchange.elapsed, id: "\(base)-retry-\(index)"))
            case .malformedRetry: out.append(.retried(exchange.request, kind: .malformed, duration: exchange.elapsed, id: "\(base)-retry-\(index)"))
            case .plan, .codegen: break
            }
        }
        if let title = interaction.finalTitle, interaction.finalSource != nil {
            // The codegen exchange that produced the final source times this turn.
            let codegenElapsed = interaction.exchanges.last { $0.producedSource != nil }?.elapsed
            out.append(.assistant(title: title, summary: "Generated shader", duration: codegenElapsed, id: "\(base)-result"))
        } else if let error = interaction.failureError {
            out.append(.error(error, duration: interaction.exchanges.last?.elapsed, id: "\(base)-error"))
        }
        return out
    }

    // MARK: - Transcript

    private var transcript: some View {
        let turns = displayTurns
        return ScrollViewReader { proxy in
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
            .onChange(of: turns.count) { _, _ in scrollToEnd(proxy, turns: turns) }
            .onChange(of: isGenerating) { _, _ in scrollToEnd(proxy, turns: turns) }
            .onAppear { scrollToEnd(proxy, turns: turns) }
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

    private func scrollToEnd(_ proxy: ScrollViewProxy, turns: [GenerationTurn]) {
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
                // Enter sends; Shift+Enter inserts a newline (#101). Returning
                // `.ignored` (incl. when Shift is held) lets the vertical
                // TextField insert the newline itself.
                .onKeyPress(keys: [.return]) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    submit()
                    return .handled
                }

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
                .disabled(interactions.isEmpty)

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
            document: TranscriptDocument(log: exportLog),
            contentType: .json,
            defaultFilename: "Transcript"
        ) { _ in }
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    /// The log to export: built from the live in-memory session state (the
    /// nested interactions), so it works identically for saved and unsaved
    /// documents (#99).
    private var exportLog: GenerationLog {
        GenerationLog(identity: logIdentity ?? "unsaved", interactions: interactions)
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
        // The document source the interaction operates on, captured before we
        // write anything (#99).
        let sourceBefore = text
        let runStarted = Date()
        // Begin the in-progress interaction (rendered live, becomes an
        // `Interaction` on completion).
        inProgressPrompt = submitted
        inProgressTurns = []
        prompt = ""
        isGenerating = true
        onGeneratingChange(true)
        status = .generating(attempt: 1, isModifying: modifying, sourceByteCount: sentBytes)
        defer {
            isGenerating = false
            onGeneratingChange(false)
            status = nil
            inProgressPrompt = nil
            inProgressTurns = []
            promptFocused = true
        }

        do {
            let adapter = try FoundationModelAdapter.make(model: selectedModel)
            let result = try await ShaderGenerator(model: adapter).generate(
                prompt: submitted,
                existingSource: sentSource,
                plan: planFirst
            ) { phase in
                status = GenerationStatus(phase: phase, isModifying: modifying, sourceByteCount: sentBytes)
                // Emit live bubbles for the in-progress interaction so the
                // plan / retry steps appear as they happen.
                switch phase {
                case .retrying(let compileError):
                    inProgressTurns.append(.retried(compileError, kind: .compile))

                case .retryingMalformed(let decodeError):
                    inProgressTurns.append(.retried(decodeError, kind: .malformed))

                case .planned(let plan):
                    inProgressTurns.append(.plan(intent: plan.intent, shape: plan.shape.displayName, body: plan.plan))

                case .generating, .planning:
                    break
                }
            }
            if let textMutator {
                textMutator.apply(result.source, actionName: modifying ? "Modify Shader" : "Generate Shader")
            } else {
                text = result.source
                onTextChange()
            }
            // We just wrote the source ourselves; record what we expect so the
            // text onChange doesn't re-hydrate and wipe the transcript.
            seededFromSource = result.source
            record(Interaction(
                startedAt: runStarted, prompt: submitted,
                sourceBefore: sourceBefore, exchanges: result.exchanges
            ))
        } catch {
            // Unwrap GenerationFailure so the user sees the real error, and we
            // keep the exchanges captured up to the failure (#99).
            let underlying: any Error
            let exchanges: [GenerationExchange]
            if let failure = error as? GenerationFailure {
                underlying = failure.underlying
                exchanges = failure.exchanges
            } else {
                underlying = error
                exchanges = []
            }
            // Ensure the terminal error is captured on the exchanges so it's
            // derivable from the log. If the last exchange didn't already
            // record an error (e.g. emptyBody after a successful decode),
            // append a synthetic terminal-error exchange.
            var finalExchanges = exchanges
            if finalExchanges.last?.error == nil {
                finalExchanges.append(GenerationExchange(
                    kind: .codegen, model: selectedModel.displayName,
                    instructions: "", request: submitted,
                    error: "\(underlying)", startedAt: runStarted, elapsed: 0))
            }
            record(Interaction(
                startedAt: runStarted, prompt: submitted,
                sourceBefore: sourceBefore, exchanges: finalExchanges
            ))
        }
    }

    /// Appends a completed interaction to the session source of truth, and
    /// mirrors it to disk for saved documents (#99).
    private func record(_ interaction: Interaction) {
        interactions.append(interaction)
        if let logIdentity {
            GenerationLogStore.appendInteraction(identity: logIdentity, interaction: interaction)
        }
    }

    // MARK: - Hydration

    /// Seed the transcript from prompts embedded in the source the first time
    /// we see a given document, and whenever the source changes to one we
    /// didn't write ourselves (e.g. switching shaders in a bundle). Responses
    /// aren't persisted, so re-hydrated turns are user prompts only.
    private func hydrateIfNeeded() {
        guard seededFromSource != text else { return }
        seededFromSource = text
        // Prefer the persisted JSON log (full nested history); fall back to
        // user prompts embedded in the source (#99). Only saved documents
        // have an on-disk log.
        if let logIdentity, let log = GenerationLogStore.load(identity: logIdentity), !log.interactions.isEmpty {
            interactions = log.interactions
            hydratedPrompts = []
        } else {
            interactions = []
            hydratedPrompts = PromptHistory.extract(from: text)
        }
    }
}

/// Human-readable elapsed time, e.g. "0.8s" or "1m 12s".
private func formattedDuration(_ seconds: Double) -> String {
    if seconds < 60 {
        return String(format: "%.1fs", seconds)
    }
    let whole = Int(seconds.rounded())
    return "\(whole / 60)m \(whole % 60)s"
}

/// A small trailing duration badge for non-user turns.
private struct DurationBadge: View {
    let seconds: Double

    var body: some View {
        Label(formattedDuration(seconds), systemImage: "clock")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
    }
}

/// Text that collapses behind a disclosure when it exceeds a line threshold.
///
/// Short text renders plainly. Long text is line-limited and shown with a
/// "Show more" / "Show less" toggle; default collapsed. Used for long fields
/// across the transcript — user prompts (#102), plan prose, retry/compiler
/// errors, and terminal errors — so one giant bubble can't dominate the chat.
private struct CollapsibleText: View {
    let text: String
    var font: Font.TextStyle = .body
    var design: Font.Design = .default
    /// Lines shown while collapsed.
    var collapsedLineLimit: Int = 3
    /// Collapse only when the text exceeds this many lines or characters.
    var lineThreshold: Int = 4
    var characterThreshold: Int = 280

    @State private var expanded = false

    private var isLong: Bool {
        let lineCount = text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        return lineCount > lineThreshold || text.count > characterThreshold
    }

    var body: some View {
        if isLong {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(font, design: design))
                    .lineLimit(expanded ? nil : collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        } else {
            Text(text)
                .font(.system(font, design: design))
                .fixedSize(horizontal: false, vertical: true)
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
            // Long pasted prompts (e.g. whole shaders) collapse so one bubble
            // can't dominate the transcript (#102).
            bubble(
                alignment: .trailing,
                background: Color.accentColor.opacity(0.18),
                content: CollapsibleText(text: turn.text)
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
                        Spacer(minLength: 4)
                        durationBadge
                    }
                    CollapsibleText(text: turn.text, font: .caption)
                        .foregroundStyle(.secondary)
                }
            )

        case .assistant(let title):
            bubble(
                alignment: .leading,
                background: Color.secondary.opacity(0.12),
                content: VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Label(title, systemImage: "sparkles")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 4)
                        durationBadge
                    }
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
                    HStack(spacing: 6) {
                        Label(retryHeadline(kind), systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Spacer(minLength: 4)
                        durationBadge
                    }
                    CollapsibleText(text: turn.text, font: .caption2, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
            )

        case .error:
            bubble(
                alignment: .leading,
                background: Color.red.opacity(0.12),
                content: VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("Error", systemImage: "exclamationmark.triangle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                        Spacer(minLength: 4)
                        durationBadge
                    }
                    CollapsibleText(text: turn.text, font: .caption)
                        .foregroundStyle(.red)
                }
            )
        }
    }

    /// Trailing duration badge, shown when the turn carries an elapsed time.
    @ViewBuilder
    private var durationBadge: some View {
        if let duration = turn.duration {
            DurationBadge(seconds: duration)
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
