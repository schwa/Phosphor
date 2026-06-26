import CollaborationKit
import Foundation
import Metal
import Observation
import PhosphorGeneration
import SwiftUI

/// A single item in the streaming conversation transcript.
///
/// Items are appended/mutated live from the ``ConversationalGenerator`` event
/// stream: the user's prompt, the assistant's streamed prose, and one row per
/// tool call (which fills in its result when the tool returns).
struct ConversationItem: Identifiable {
    enum Kind {
        /// A user prompt, with any attached input images.
        case user(String, images: [ImageContent] = [])
        /// Streamed assistant prose; `text` grows as deltas arrive.
        case assistant(String)
        /// A tool invocation: name + a short argument summary + a result that
        /// fills in when the tool returns. `isError` flags a failed result.
        case tool(name: String, summary: String, result: String?, isError: Bool)
        /// A harness/transport error that ended the turn.
        case error(String)
    }

    let id = UUID()
    var kind: Kind
    /// When this item was first created (the user sent it, the assistant
    /// started replying, or a tool was invoked).
    let timestamp = Date()
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
@MainActor
@Observable
final class ConversationStore {
    /// The streaming transcript, oldest first.
    private(set) var items: [ConversationItem] = []
    /// True while a turn is in flight.
    private(set) var isGenerating = false
    /// Cumulative token usage across the session.
    private(set) var usage = TokenUsage()
    /// The last harness error, surfaced to the user (not a tool error).
    private(set) var lastError: String?

    private let device: MTLDevice
    private let readSource: @MainActor () -> String
    private let writeSource: @MainActor (String, String) -> Void

    private var document: MetalSourceDocument?
    private var generator: ConversationalGenerator?
    private var eventTask: Task<Void, Never>?
    /// Index of the assistant item currently receiving streamed deltas, if any.
    private var streamingAssistantIndex: Int?
    /// Maps a tool-use id to the transcript index of its row, so the result can
    /// be filled in when it returns.
    private var toolRowIndex: [String: Int] = [:]

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
        // Snapshot the pre-turn editor source now (synchronously) so a later
        // "roll back to here" can restore exactly what the shader was before
        // this prompt ran. The history length is filled in in `run()`.
        var userItem = ConversationItem(kind: .user(trimmed, images: images))
        userItem.rollbackSnapshot = RollbackSnapshot(source: readSource(), messageCount: 0)
        let userItemID = userItem.id
        items.append(userItem)
        isGenerating = true

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
    /// model's memory to that point, and drops every transcript item from this
    /// prompt onward. A no-op while a turn is generating.
    func rollBack(to id: ConversationItem.ID) {
        guard !isGenerating,
              let index = items.firstIndex(where: { $0.id == id }),
              let snapshot = items[index].rollbackSnapshot else { return }

        // Restore the editor source as an undoable edit.
        writeSource(snapshot.source, "Roll Back Shader")
        // Keep the document buffer the tools see in sync.
        document?.setSource(snapshot.source)

        // Drop this prompt and everything after it from the UI transcript.
        items.removeLast(items.count - index)
        lastError = nil
        streamingAssistantIndex = nil
        toolRowIndex.removeAll()

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
        }

        let generator: ConversationalGenerator
        do {
            generator = try ensureGenerator()
        } catch {
            items.append(ConversationItem(kind: .error(error.localizedDescription)))
            lastError = error.localizedDescription
            return
        }

        // Record the history length before this turn appends its user message,
        // so rollback can truncate the model's memory back to exactly here.
        let priorMessageCount = await generator.messages.count
        if let index = items.firstIndex(where: { $0.id == userItemID }),
           let source = items[index].rollbackSnapshot?.source {
            items[index].rollbackSnapshot = RollbackSnapshot(source: source, messageCount: priorMessageCount)
        }

        // Seed the document buffer with the editor's current text so the tools
        // operate on the latest source (the user may have hand-edited it).
        document?.setSource(readSource())

        do {
            _ = try await generator.send(trimmed, images: images)
        } catch is CancellationError {
            items.append(ConversationItem(kind: .error("Stopped.")))
        } catch {
            if Task.isCancelled {
                items.append(ConversationItem(kind: .error("Stopped.")))
            } else {
                items.append(ConversationItem(kind: .error("\(error)")))
                lastError = "\(error)"
            }
        }
        streamingAssistantIndex = nil
        usage = await generator.totalUsage
    }

    /// The serialized session transcript, for persistence in a bundle (#83).
    func serializedMessages() async -> [Message] {
        await generator?.messages ?? []
    }

    /// Builds a complete, debuggable snapshot of the session: the full raw
    /// transcript, system prompt, model, usage, current source, and the live UI
    /// transcript. Safe to call with no session yet (exports what's available).
    func buildExport() async -> ConversationExport {
        let messages = await generator?.messages ?? []
        let liveUsage = await generator?.totalUsage ?? usage
        return ConversationExport(
            exportedAt: Date(),
            model: ConversationProvider.exportModelLabel,
            instructions: generator?.instructions ?? ConversationalGenerator.defaultInstructions,
            usage: liveUsage,
            lastError: lastError,
            currentSource: readSource(),
            messages: messages,
            uiTranscript: items,
            transcriptSpanMS: ConversationExport.transcriptSpanMS(items)
        )
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

        case .text:
            // The full block is already accumulated via deltas; close the
            // current streaming item so the next prose starts a fresh bubble.
            finishStreamingAssistant()

        case .toolCall(let use):
            finishStreamingAssistant()
            let latency = latencyForNextItem()
            let index = items.count
            var item = ConversationItem(kind: .tool(
                name: use.name,
                summary: Self.summary(for: use),
                result: nil,
                isError: false
            ))
            item.latency = latency
            items.append(item)
            toolRowIndex[use.id] = index

        case .toolResult(let result):
            guard let index = toolRowIndex[result.toolUseID], items.indices.contains(index),
                  case .tool(let name, let summary, _, _) = items[index].kind else { return }
            items[index].kind = .tool(
                name: name,
                summary: summary,
                result: result.content,
                isError: result.isError
            )
            items[index].duration = Date().timeIntervalSince(items[index].timestamp)

        case .usage(let turnUsage):
            usage += turnUsage

        case .turnComplete:
            finishStreamingAssistant()
        }
    }

    /// Closes the current streaming assistant bubble, recording how long it took.
    private func finishStreamingAssistant() {
        if let index = streamingAssistantIndex, items.indices.contains(index) {
            items[index].duration = Date().timeIntervalSince(items[index].timestamp)
        }
        streamingAssistantIndex = nil
    }

    private func appendAssistantDelta(_ chunk: String) {
        if let index = streamingAssistantIndex, items.indices.contains(index),
           case .assistant(let existing) = items[index].kind {
            items[index].kind = .assistant(existing + chunk)
        } else {
            let latency = latencyForNextItem()
            var item = ConversationItem(kind: .assistant(chunk))
            item.latency = latency
            items.append(item)
            streamingAssistantIndex = items.count - 1
        }
    }

    /// The wall-clock gap between the last item completing and now, used as the
    /// "round-trip" latency for the item about to be appended. `nil` when there
    /// is no prior item.
    private func latencyForNextItem() -> TimeInterval? {
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
