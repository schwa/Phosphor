import CollaborationKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A complete, debuggable snapshot of a conversational generation session.
///
/// This is the "export EVERYTHING" record: the full raw `LLMSession.messages`
/// transcript (every text / tool-use / tool-result block, losslessly), the
/// system prompt and model, cumulative token usage, the current `.metal`
/// source, the last harness error, and the live UI transcript. Serialized as
/// pretty JSON so a bug report carries the exact inputs and outputs.
///
/// `nonisolated`: a pure value-type snapshot. The app target defaults types to
/// `@MainActor`, but `Transferable` requires nonisolated conformance.
nonisolated struct ConversationExport: Codable, Sendable {
    var exportedAt: Date
    var model: String
    var instructions: String
    var usage: UsageDTO
    var lastError: String?
    /// The current full `.metal` source at export time.
    var currentSource: String
    /// The raw session transcript — the authoritative record.
    var messages: [MessageDTO]
    /// The projected UI transcript, as the user saw it.
    var uiTranscript: [UIItemDTO]

    struct UsageDTO: Codable {
        var inputTokens: Int
        var outputTokens: Int
        var totalTokens: Int

        init(_ usage: TokenUsage) {
            self.inputTokens = usage.inputTokens
            self.outputTokens = usage.outputTokens
            self.totalTokens = usage.totalTokens
        }
    }

    struct MessageDTO: Codable {
        var role: String
        var blocks: [BlockDTO]

        init(_ message: Message) {
            self.role = message.role.rawValue
            self.blocks = message.content.map(BlockDTO.init)
        }
    }

    /// One content block. Exactly one payload field is populated per block.
    struct BlockDTO: Codable {
        var type: String
        var text: String?
        var toolUse: ToolUseDTO?
        var toolResult: ToolResultDTO?

        init(_ block: ContentBlock) {
            switch block {
            case .text(let text):
                self.type = "text"
                self.text = text

            case .toolUse(let use):
                self.type = "toolUse"
                self.toolUse = ToolUseDTO(use)

            case .toolResult(let result):
                self.type = "toolResult"
                self.toolResult = ToolResultDTO(result)
            }
        }
    }

    struct ToolUseDTO: Codable {
        var id: String
        var name: String
        var input: JSONValue

        init(_ use: ToolUse) {
            self.id = use.id
            self.name = use.name
            self.input = use.input
        }
    }

    struct ToolResultDTO: Codable {
        var toolUseID: String
        var content: String
        var isError: Bool

        init(_ result: ToolResult) {
            self.toolUseID = result.toolUseID
            self.content = result.content
            self.isError = result.isError
        }
    }

    /// The live UI transcript item, flattened for export.
    struct UIItemDTO: Codable {
        var kind: String
        var text: String?
        var toolName: String?
        var toolSummary: String?
        var toolResult: String?
        var isError: Bool?

        init(_ item: ConversationItem) {
            switch item.kind {
            case .user(let text):
                self.kind = "user"
                self.text = text

            case .assistant(let text):
                self.kind = "assistant"
                self.text = text

            case .tool(let name, let summary, let result, let isError):
                self.kind = "tool"
                self.toolName = name
                self.toolSummary = summary
                self.toolResult = result
                self.isError = isError

            case .error(let message):
                self.kind = "error"
                self.text = message
            }
        }
    }

    /// Pretty-printed JSON for the export file.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

// Conform to `Transferable` so the export drives `fileExporter(item:)` and
// `ShareLink` directly — no `FileDocument` wrapper (per the SwiftUI house
// rules: prefer `Transferable` for one-off save/share flows).
nonisolated extension ConversationExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { export in
            try export.jsonData()
        }
        .suggestedFileName { _ in "Phosphor-Session.json" }
    }
}
