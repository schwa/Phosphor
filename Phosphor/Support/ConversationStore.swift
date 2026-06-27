import CollaborationKit
import Foundation
import Metal
import Observation
import PhosphorGeneration
import SwiftUI

/// A stable identity for a projected transcript row.
///
/// The UI transcript is a pure projection of the model's ``Message`` history
/// (plus two overlays that have no home in that history: live streaming and
/// harness errors). Each logical row carries a key so re-projecting the same
/// history yields the same row identity — which keeps SwiftUI's `ForEach`,
/// scroll position, and `.id()` stable across updates.
enum ProjectionKey: Hashable {
    /// A user prompt at the given history index.
    case user(Int)
    /// A finalized assistant prose row at the given history index.
    case assistant(Int)
    /// A tool row, merged use+result, keyed by the provider-assigned tool-use id.
    case tool(String)
    /// The in-flight assistant bubble streaming deltas for the current turn.
    case streamingAssistant
    /// A harness/transport error overlay (not part of the model history).
    case error(Int)
}

/// A single item in the conversation transcript.
///
/// Items are a *projection* of the session's ``Message`` history: the store
/// never accumulates them by hand. Each carries presentation-only metadata
/// (timestamps, durations, latency) merged in from a side-table keyed by
/// ``ProjectionKey``, plus a stable ``id`` so SwiftUI identity survives
/// re-projection.
struct ConversationItem: Identifiable {
    enum Kind {
        /// A user prompt, with any attached input images.
        case user(String, images: [ImageContent] = [])
        /// Assistant prose. While streaming, `text` grows as deltas arrive.
        case assistant(String)
        /// A tool invocation: name + a short argument summary + a result that
        /// fills in when the tool returns. `isError` flags a failed result.
        case tool(name: String, summary: String, result: String?, isError: Bool)
        /// A harness/transport error that ended the turn.
        case error(String)
    }

    /// Stable SwiftUI identity, preserved across re-projection via the store's
    /// key→id cache.
    let id: UUID
    /// The projection key this row derives from.
    let key: ProjectionKey
    var kind: Kind
    /// When this item first appeared (user sent it, assistant started replying,
    /// or a tool was invoked).
    var timestamp: Date
    /// How long this item took to complete: assistant prose from first delta to
    /// the end of the block, a tool from invocation to result. `nil` until
    /// complete (and always `nil` for user prompts).
    var duration: TimeInterval?
    /// The wall-clock "round-trip" gap before this item appeared: the time the
    /// model/network spent between the previous item completing and this one
    /// starting. `nil` for the first item of a turn. This is the number that
    /// actually reflects how long the user waited — unlike ``duration``, which
    /// only times the visible block.
    var latency: TimeInterval?
    /// For user prompts only: a snapshot of the editor's `.metal` source and the
    /// model's history length *just before* this turn ran. Used by
    /// ``ConversationStore/rollBack(to:)`` to restore the shader and truncate
    /// the conversation to this point. `nil` for non-user items.
    var rollbackSnapshot: RollbackSnapshot?
}

/// Presentation-only metadata for one projected row, kept in a side-table
/// keyed by ``ProjectionKey``. This is the data the model history does not
/// carry (CollaborationKit's ``Message`` has no notion of time): when the row
/// appeared, how long it took, and the round-trip latency the user felt.
private struct Presentation {
    var timestamp: Date
    var duration: TimeInterval?
    var latency: TimeInterval?
    /// User-prompt rows only: the rollback snapshot captured when the turn ran.
    var rollbackSnapshot: RollbackSnapshot?
    /// Tool rows only: the short human-readable argument summary.
    var summary: String?
}

/// The state captured before a user turn, so the conversation can be rolled
/// back to just before that turn.
struct RollbackSnapshot {
    /// The `.metal` source as it was before this turn edited it.
    let source: String
    /// The model history length (``ConversationalGenerator/messages`` count)
    /// before this turn's user message was appended.
    let messageCount: Int
}

/// Owns a conversational shader-generation session and projects its live event
/// stream into an observable transcript for the Generate panel.
///
/// One store per editor document. Built lazily on the first send (so opening
/// the tab doesn't require an API key). Edits land in the live `.metal` source
/// through the host-supplied write closure (an undoable `TextMutator.apply`).
///
/// ## One source of truth
///
/// The transcript is a *pure projection* of the model's ``Message`` history
/// (``messages``) plus two overlays that genuinely live outside that history:
/// the in-flight streaming assistant bubble, and harness/transport errors. The
/// store mirrors the session's finalized messages as events arrive, records
/// presentation metadata (timestamps, durations, latency, tool summaries) in a
/// side-table, and recomputes ``items`` from those. Rollback then only has to
/// truncate one history; the UI re-derives.
@MainActor
@Observable
final class ConversationStore {
    /// The model's finalized message history, mirrored from the session as
    /// events arrive. The single source of truth the transcript projects from.
    private(set) var messages: [Message] = []
    /// The projected transcript, oldest first. Recomputed from ``messages`` plus
    /// the streaming/error overlays whenever either changes.
    private(set) var items: [ConversationItem] = []
    /// True while a turn is in flight.
    private(set) var isGenerating = false
    /// Cumulative token usage across the session.
    private(set) var usage = TokenUsage()
    /// The last harness error, surfaced to the user (not a tool error).
    private(set) var lastError: String?

    // MARK: Projection inputs

    /// Live assistant prose for the current streaming bubble, before it is
    /// finalized into ``messages``. `nil` when not streaming.
    private var streamingAssistantText: String?
    /// Harness/transport errors, which have no place in the model history.
    private var errorOverlays: [(seq: Int, message: String)] = []
    private var errorSeq = 0
    /// Stable id per projection key, so re-projection preserves SwiftUI identity.
    private var idByKey: [ProjectionKey: UUID] = [:]
    /// Presentation metadata (timestamps/durations/latency/summaries) per key.
    private var presentation: [ProjectionKey: Presentation] = [:]

    private let device: MTLDevice
    private let readSource: @MainActor () -> String
    private let writeSource: @MainActor (String, String) -> Void

    private var document: MetalSourceDocument?
    private var generator: ConversationalGenerator?
    private var eventTask: Task<Void, Never>?

    /// - Parameters:
    ///   - device: Metal device for the `compileShader` tool.
    ///   - readSource: Returns the current full `.metal` source.
    ///   - writeSource: Applies a full-text replacement as an undoable edit
    ///     (newText, actionName).
    init(device: MTLDevice, readSource: @escaping @MainActor () -> String, writeSource: @escaping @MainActor (String, String) -> Void) {
        self.device = device
        self.readSource = readSource
        self.writeSource = writeSource
    }

    var isEmpty: Bool { items.isEmpty }

    /// The in-flight generation task, if any. Tracked so ``stop()`` can cancel
    /// it.
    private var sendTask: Task<Void, Never>?

    /// Starts a turn: appends the user message and runs the agentic tool loop
    /// in a cancellable task. Streams events into ``items`` as they arrive; the
    /// live document updates during the turn.
    func send(_ prompt: String, images: [ImageContent] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.isEmpty && images.isEmpty), !isGenerating else { return }

        lastError = nil
        // Append the user message to our mirror now, synchronously, and capture
        // the pre-turn editor source so a later "roll back to here" can restore
        // exactly what the shader was before this prompt ran. The history length
        // is filled in in `run()`.
        let userIndex = messages.count
        messages.append(images.isEmpty ? .user(trimmed) : .user(text: trimmed, images: images))
        let key = ProjectionKey.user(userIndex)
        presentation[key, default: Presentation(timestamp: Date())].rollbackSnapshot =
            RollbackSnapshot(source: readSource(), messageCount: 0)
        let userItemID = ensureID(for: key)
        isGenerating = true
        reproject()

        sendTask = Task { [weak self] in
            await self?.run(trimmed, images: images, userItemID: userItemID)
        }
    }

    /// Cancels the in-flight turn, if any. The tool loop stops at its next
    /// cooperative cancellation point and the document keeps whatever edits the
    /// model already applied.
    func stop() {
        guard isGenerating else { return }
        sendTask?.cancel()
    }

    /// True when the item at `id` is a user prompt that can be rolled back to
    /// (it carries a snapshot and a turn isn't in flight).
    func canRollBack(to id: ConversationItem.ID) -> Bool {
        guard !isGenerating, let item = items.first(where: { $0.id == id }) else { return false }
        return item.rollbackSnapshot != nil
    }

    /// Rolls the whole session back to just before the user prompt at `id`:
    /// restores the `.metal` source to its pre-turn snapshot, truncates the
    /// model's memory to that point, and re-projects the transcript. A no-op
    /// while a turn is generating.
    ///
    /// Because the transcript is a projection of ``messages``, rollback only has
    /// to truncate the one history (model + mirror) — the UI rows fall away on
    /// the next ``reproject()``.
    func rollBack(to id: ConversationItem.ID) {
        guard !isGenerating,
              let item = items.first(where: { $0.id == id }),
              case .user(let userIndex) = item.key,
              let snapshot = item.rollbackSnapshot else { return }

        // Restore the editor source as an undoable edit.
        writeSource(snapshot.source, "Roll Back Shader")
        // Keep the document buffer the tools see in sync.
        document?.setSource(snapshot.source)

        // Truncate the single source of truth to just before this user message.
        messages.removeLast(messages.count - userIndex)
        lastError = nil
        streamingAssistantText = nil
        errorOverlays.removeAll()
        reproject()

        // Truncate the model's memory to the same point.
        let keep = snapshot.messageCount
        if let generator {
            Task { await generator.truncateHistory(keeping: keep) }
        }
    }

    private func run(_ trimmed: String, images: [ImageContent], userItemID: UUID) async {
        defer {
            isGenerating = false
            sendTask = nil
            reproject()
        }

        let generator: ConversationalGenerator
        do {
            generator = try ensureGenerator()
        } catch {
            appendError(error.localizedDescription)
            lastError = error.localizedDescription
            return
        }

        // Record the history length before this turn appends its user message,
        // so rollback can truncate the model's memory back to exactly here.
        let priorMessageCount = await generator.messages.count
        if let item = items.first(where: { $0.id == userItemID }),
           case .user(let userIndex) = item.key,
           let source = presentation[.user(userIndex)]?.rollbackSnapshot?.source {
            presentation[.user(userIndex)]?.rollbackSnapshot =
                RollbackSnapshot(source: source, messageCount: priorMessageCount)
            reproject()
        }

        // Seed the document buffer with the editor's current text so the tools
        // operate on the latest source (the user may have hand-edited it).
        document?.setSource(readSource())

        do {
            _ = try await generator.send(trimmed, images: images)
        } catch is CancellationError {
            appendError("Stopped.")
        } catch {
            if Task.isCancelled {
                appendError("Stopped.")
            } else {
                appendError("\(error)")
                lastError = "\(error)"
            }
        }
        streamingAssistantText = nil
        usage = await generator.totalUsage
        // Refresh the mirror from the session's authoritative history so the
        // projection reflects exactly what the model now remembers.
        messages = await generator.messages
    }

    /// The serialized session transcript, for persistence in a bundle (#83).
    func serializedMessages() async -> [Message] {
        await generator?.messages ?? []
    }

    /// Builds a complete, debuggable snapshot of the session: the full raw
    /// transcript, system prompt, model, usage, current source, and the live UI
    /// transcript. Safe to call with no session yet (exports what's available).
    func buildExport() async -> ConversationExport {
        let sessionMessages = await generator?.messages ?? messages
        let liveUsage = await generator?.totalUsage ?? usage
        return ConversationExport(
            exportedAt: Date(),
            model: ConversationProvider.exportModelLabel,
            instructions: generator?.instructions ?? ConversationalGenerator.defaultInstructions,
            usage: liveUsage,
            lastError: lastError,
            currentSource: readSource(),
            messages: sessionMessages,
            uiTranscript: items,
            transcriptSpanMS: ConversationExport.transcriptSpanMS(items)
        )
    }

    // MARK: - Projection

    /// Recomputes ``items`` from ``messages`` plus the streaming and error
    /// overlays. This is the only place that builds the transcript — there is no
    /// hand-accumulation, so the UI cannot structurally drift from the model.
    private func reproject() {
        var rows: [ConversationItem] = []
        var liveKeys: Set<ProjectionKey> = []

        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                // A user message is always a prompt now: tool results live
                // inside the assistant message's ToolCall, not in a user message.
                if let (text, images) = userPrompt(message) {
                    let key = ProjectionKey.user(index)
                    liveKeys.insert(key)
                    rows.append(makeRow(key: key, kind: .user(text, images: images)))
                }

            case .assistant:
                appendAssistantRows(message, index: index, into: &rows, liveKeys: &liveKeys)
            }
        }

        // Overlay: the in-flight assistant bubble (deltas not yet finalized).
        if let streaming = streamingAssistantText {
            let key = ProjectionKey.streamingAssistant
            liveKeys.insert(key)
            rows.append(makeRow(key: key, kind: .assistant(streaming)))
        }

        // Overlay: harness errors, which never enter the model history.
        for error in errorOverlays {
            let key = ProjectionKey.error(error.seq)
            liveKeys.insert(key)
            rows.append(makeRow(key: key, kind: .error(error.message)))
        }

        // Drop presentation/id entries for keys that no longer project (e.g.
        // after rollback), so the side-tables don't grow without bound.
        for key in Set(idByKey.keys).subtracting(liveKeys) {
            idByKey[key] = nil
            presentation[key] = nil
        }
        items = rows
    }

    /// Extracts a user *prompt* (text + images) from a user message, or `nil`
    /// when the message only carries tool results.
    private func userPrompt(_ message: Message) -> (String, [ImageContent])? {
        var text = ""
        var images: [ImageContent] = []
        var sawPromptContent = false
        for block in message.content {
            switch block {
            case .text(let value):
                text = value
                sawPromptContent = true

            case .image(let image):
                images.append(image)
                sawPromptContent = true

            case .toolCall:
                break
            }
        }
        return sawPromptContent ? (text, images) : nil
    }

    /// Projects an assistant message into one prose row (if it has text) plus
    /// one row per tool call. Each ``ToolCall`` owns its result, so a tool row's
    /// result fills in from the same block — no separate result message.
    private func appendAssistantRows(_ message: Message, index: Int, into rows: inout [ConversationItem], liveKeys: inout Set<ProjectionKey>) {
        var prose = ""
        for block in message.content {
            if case .text(let value) = block { prose += value }
        }
        if !prose.isEmpty {
            let key = ProjectionKey.assistant(index)
            liveKeys.insert(key)
            rows.append(makeRow(key: key, kind: .assistant(prose)))
        }
        for block in message.content {
            guard case .toolCall(let call) = block else { continue }
            let key = ProjectionKey.tool(call.use.id)
            liveKeys.insert(key)
            let summary = presentation[key]?.summary ?? Self.summary(for: call.use)
            rows.append(makeRow(key: key, kind: .tool(
                name: call.use.name,
                summary: summary,
                result: call.result?.content,
                isError: call.result?.isError ?? false
            )))
        }
    }

    /// Builds one projected row, merging in its presentation metadata and stable id.
    private func makeRow(key: ProjectionKey, kind: ConversationItem.Kind) -> ConversationItem {
        let meta = presentation[key] ?? Presentation(timestamp: Date())
        if presentation[key] == nil { presentation[key] = meta }
        return ConversationItem(
            id: ensureID(for: key),
            key: key,
            kind: kind,
            timestamp: meta.timestamp,
            duration: meta.duration,
            latency: meta.latency,
            rollbackSnapshot: meta.rollbackSnapshot
        )
    }

    private func ensureID(for key: ProjectionKey) -> UUID {
        if let id = idByKey[key] { return id }
        let id = UUID()
        idByKey[key] = id
        return id
    }

    private func appendError(_ message: String) {
        errorSeq += 1
        let seq = errorSeq
        errorOverlays.append((seq: seq, message: message))
        presentation[.error(seq)] = Presentation(timestamp: Date())
        reproject()
    }

    // MARK: - Generator + event pump

    private func ensureGenerator() throws -> ConversationalGenerator {
        if let generator { return generator }

        // The write observer fires on a background tool-loop thread; hop to the
        // main actor to push the edit into the SwiftUI editor (undoably).
        // Capture only the @Sendable write closure, never `self`, so the
        // observer body stays Sendable.
        let apply = writeSource
        let document = MetalSourceDocument(source: readSource()) { newText in
            Task { @MainActor in
                apply(newText, "Generate Shader")
            }
        }
        let provider = try ConversationProvider.make()
        let generator = ConversationalGenerator(provider: provider, document: document, device: device)
        self.document = document
        self.generator = generator
        startPump(generator)
        return generator
    }

    private func startPump(_ generator: ConversationalGenerator) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            for await event in generator.events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .textDelta(let chunk):
            appendAssistantDelta(chunk)

        case .text(let block):
            // The block is complete: finalize it into the mirror so it persists
            // as a projected row, then clear the streaming overlay (carrying its
            // timestamp/latency/duration onto the finalized row's key).
            finalizeAssistantProse(block)

        case .toolCall(let use):
            finishStreamingAssistant()
            let key = ProjectionKey.tool(use.id)
            var meta = Presentation(timestamp: Date())
            meta.latency = latencyForNextRow()
            meta.summary = Self.summary(for: use)
            presentation[key] = meta
            // Mirror the tool call into history so the row projects immediately,
            // before the session's authoritative refresh at turn end.
            appendToolUseToMirror(use)
            reproject()

        case .toolResult(let result):
            let key = ProjectionKey.tool(result.toolUseID)
            // Compute the duration from a local copy first: reading and modifying
            // `presentation` in one statement trips Swift's exclusive-access
            // enforcement (it's an @Observable-tracked property).
            if let start = presentation[key]?.timestamp {
                presentation[key]?.duration = Date().timeIntervalSince(start)
            }
            attachResultToMirror(result)
            reproject()

        case .usage(let turnUsage):
            usage += turnUsage

        case .turnComplete:
            finishStreamingAssistant()
        }
    }

    /// Finalizes a completed assistant prose block into the message mirror,
    /// keyed by its history index, and clears the streaming overlay — moving the
    /// overlay's presentation metadata (timestamp/latency, plus a freshly
    /// stamped duration) onto the finalized row so the visible timing survives.
    private func finalizeAssistantProse(_ block: String) {
        let index = appendAssistantProseToMirror(block)
        let destKey = ProjectionKey.assistant(index)
        let streamKey = ProjectionKey.streamingAssistant
        if var meta = presentation[streamKey] {
            meta.duration = Date().timeIntervalSince(meta.timestamp)
            // Preserve identity: hand the streaming row's id to the finalized row
            // so it doesn't flash as a new bubble.
            if let id = idByKey[streamKey] { idByKey[destKey] = id }
            presentation[destKey] = meta
        }
        presentation[streamKey] = nil
        idByKey[streamKey] = nil
        streamingAssistantText = nil
        reproject()
    }

    /// Clears the streaming overlay without finalizing (turn end / tool break
    /// where no `.text` block arrived). Stamps duration for completeness.
    private func finishStreamingAssistant() {
        if streamingAssistantText != nil {
            let key = ProjectionKey.streamingAssistant
            if let start = presentation[key]?.timestamp {
                presentation[key]?.duration = Date().timeIntervalSince(start)
            }
        }
        streamingAssistantText = nil
        reproject()
    }

    /// Appends a finalized assistant prose block to the mirror, merging into the
    /// trailing assistant message when it has no prose yet. Returns the history
    /// index of the assistant message holding it.
    private func appendAssistantProseToMirror(_ block: String) -> Int {
        if let last = messages.indices.last, messages[last].role == .assistant,
           !messages[last].content.contains(where: { if case .text = $0 { return true } else { return false } }) {
            messages[last].content.insert(.text(block), at: 0)
            return last
        }
        messages.append(Message(role: .assistant, content: [.text(block)]))
        return messages.count - 1
    }

    private func appendAssistantDelta(_ chunk: String) {
        if streamingAssistantText == nil {
            var meta = Presentation(timestamp: Date())
            meta.latency = latencyForNextRow()
            presentation[.streamingAssistant] = meta
            streamingAssistantText = chunk
        } else {
            streamingAssistantText? += chunk
        }
        reproject()
    }

    /// Appends a pending tool call to the mirror so its row projects live. The
    /// trailing assistant message accumulates the turn's tool calls.
    private func appendToolUseToMirror(_ use: ToolUse) {
        let call = ToolCall(use: use)
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].content.append(.toolCall(call))
        } else {
            messages.append(Message(role: .assistant, content: [.toolCall(call)]))
        }
    }

    /// Fills in a pending tool call's result in the mirror, matched by tool-use
    /// id, so the existing tool row updates in place (domain shape: the result
    /// lives inside the ToolCall, not in a separate message).
    private func attachResultToMirror(_ result: ToolResult) {
        for messageIndex in messages.indices.reversed() {
            for blockIndex in messages[messageIndex].content.indices {
                if case .toolCall(var call) = messages[messageIndex].content[blockIndex],
                   call.use.id == result.toolUseID {
                    call.result = result
                    messages[messageIndex].content[blockIndex] = .toolCall(call)
                    return
                }
            }
        }
    }

    /// The wall-clock gap between the last projected row completing and now,
    /// used as the "round-trip" latency for the row about to appear. `nil` when
    /// there is no prior row.
    private func latencyForNextRow() -> TimeInterval? {
        guard let last = items.last else { return nil }
        let lastEnd = last.timestamp.addingTimeInterval(last.duration ?? 0)
        return Date().timeIntervalSince(lastEnd)
    }

    /// A short, human-readable argument summary for a tool-call row.
    private static func summary(for use: ToolUse) -> String {
        switch use.name {
        case "read": return "reading the source"

        case "write": return "rewriting the source"

        case "edit":
            if case .object(let fields) = use.input, case .string(let old)? = fields["oldText"] {
                return "replacing “\(old.prefix(40))…”"
            }
            return "editing the source"

        case "writeConfiguration": return "updating configuration"

        case "readConfiguration": return "reading configuration"

        case "compileShader": return "compiling"

        default: return use.name
        }
    }
}
