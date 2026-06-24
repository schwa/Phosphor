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
        case user(String)
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
    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        lastError = nil
        items.append(ConversationItem(kind: .user(trimmed)))
        isGenerating = true

        sendTask = Task { [weak self] in
            await self?.run(trimmed)
        }
    }

    /// Cancels the in-flight turn, if any. The tool loop stops at its next
    /// cooperative cancellation point and the document keeps whatever edits the
    /// model already applied.
    func stop() {
        guard isGenerating else { return }
        sendTask?.cancel()
    }

    private func run(_ trimmed: String) async {
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

        // Seed the document buffer with the editor's current text so the tools
        // operate on the latest source (the user may have hand-edited it).
        document?.setSource(readSource())

        do {
            _ = try await generator.send(trimmed)
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
            model: ConversationProvider.model.id,
            instructions: generator?.instructions ?? ConversationalGenerator.defaultInstructions,
            usage: .init(liveUsage),
            lastError: lastError,
            currentSource: readSource(),
            messages: messages.map(ConversationExport.MessageDTO.init),
            uiTranscript: items.map(ConversationExport.UIItemDTO.init)
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
            streamingAssistantIndex = nil

        case .toolCall(let use):
            let index = items.count
            items.append(ConversationItem(kind: .tool(
                name: use.name,
                summary: Self.summary(for: use),
                result: nil,
                isError: false
            )))
            toolRowIndex[use.id] = index
            streamingAssistantIndex = nil

        case .toolResult(let result):
            guard let index = toolRowIndex[result.toolUseID], items.indices.contains(index),
                  case .tool(let name, let summary, _, _) = items[index].kind else { return }
            items[index].kind = .tool(
                name: name,
                summary: summary,
                result: result.content,
                isError: result.isError
            )

        case .usage(let turnUsage):
            usage += turnUsage

        case .turnComplete:
            streamingAssistantIndex = nil
        }
    }

    private func appendAssistantDelta(_ chunk: String) {
        if let index = streamingAssistantIndex, items.indices.contains(index),
           case .assistant(let existing) = items[index].kind {
            items[index].kind = .assistant(existing + chunk)
        } else {
            items.append(ConversationItem(kind: .assistant(chunk)))
            streamingAssistantIndex = items.count - 1
        }
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
