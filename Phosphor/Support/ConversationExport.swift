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
/// Everything here is the real model — `TokenUsage`, `Message`, and
/// `ConversationItem` — serialized directly via the `Encodable` conformances
/// in this file. There is no parallel DTO mirror: the export shape *is* the
/// model's shape (with image bytes redacted and durations surfaced in ms).
///
/// `nonisolated`: a pure value-type snapshot. The app target defaults types to
/// `@MainActor`, but `Transferable` requires nonisolated conformance.
nonisolated struct ConversationExport: Encodable, Sendable {
    var exportedAt: Date
    var model: String
    var instructions: String
    var usage: TokenUsage
    var lastError: String?
    /// The current full `.metal` source at export time.
    var currentSource: String
    /// The raw session transcript — the authoritative record.
    var messages: [Message]
    /// The projected UI transcript, as the user saw it.
    var uiTranscript: [ConversationItem]
    /// Wall-clock span of the transcript: first item's timestamp to the last
    /// item's completion. `nil` when the transcript is empty. This is the true
    /// end-to-end time the user experienced (including the gaps between items),
    /// which the per-item `durationMS` values do not capture.
    var transcriptSpanMS: Double?

    /// Computes the wall-clock span across all UI items: from the first item's
    /// timestamp to the latest (timestamp + duration) among them.
    static func transcriptSpanMS(_ items: [ConversationItem]) -> Double? {
        guard let first = items.first else { return nil }
        let start = first.timestamp
        let end = items.reduce(start) { latest, item in
            let itemEnd = item.timestamp.addingTimeInterval(item.duration ?? 0)
            return max(latest, itemEnd)
        }
        return end.timeIntervalSince(start) * 1000
    }

    /// Pretty-printed JSON for the export file.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // ISO8601 with fractional seconds: the default `.iso8601` rounds to
        // whole seconds, which hides sub-second gaps between transcript items.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
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

// MARK: - Export encodings for the real model types
//
// These retroactive `Encodable` conformances let `ConversationExport`
// serialize the live CollaborationKit / app model values directly, instead of
// copying them into export-only DTO twins. They live in the Phosphor target
// (CollaborationKit is a separate project) and define exactly one export shape
// per model type.

extension TokenUsage: @retroactive Encodable {
    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, totalTokens
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
    }
}

extension ToolUse: @retroactive Encodable {
    enum CodingKeys: String, CodingKey { case id, name, input }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(input, forKey: .input)
    }
}

extension ToolResult: @retroactive Encodable {
    enum CodingKeys: String, CodingKey { case toolUseID, content, isError }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolUseID, forKey: .toolUseID)
        try c.encode(content, forKey: .content)
        try c.encode(isError, forKey: .isError)
    }
}

/// One content block. Exactly one payload field is populated per block. Image
/// blocks record their media type and size, not the (large) base64 bytes.
extension ContentBlock: @retroactive Encodable {
    enum CodingKeys: String, CodingKey { case type, text, toolUse, toolResult }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)

        case .toolUse(let use):
            try c.encode("toolUse", forKey: .type)
            try c.encode(use, forKey: .toolUse)

        case .toolResult(let result):
            try c.encode("toolResult", forKey: .type)
            try c.encode(result, forKey: .toolResult)

        case .image(let image):
            try c.encode("image", forKey: .type)
            try c.encode("\(image.mediaType) (\(image.base64Data.count) base64 chars)", forKey: .text)
        }
    }
}

extension Message: @retroactive Encodable {
    enum CodingKeys: String, CodingKey { case role, blocks }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(content, forKey: .blocks)
    }
}

/// The live UI transcript item, flattened for export: the enum `kind` is
/// projected to discrete fields and the `TimeInterval` (seconds) durations are
/// surfaced in milliseconds. `rollbackSnapshot` is editor-only and omitted.
extension ConversationItem: Encodable {
    enum CodingKeys: String, CodingKey {
        case kind, text, toolName, toolSummary, toolResult, isError
        case timestamp, durationMS, latencyMS
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(duration.map { $0 * 1000 }, forKey: .durationMS)
        try c.encodeIfPresent(latency.map { $0 * 1000 }, forKey: .latencyMS)
        switch kind {
        case .user(let text, _):
            try c.encode("user", forKey: .kind)
            try c.encode(text, forKey: .text)

        case .assistant(let text):
            try c.encode("assistant", forKey: .kind)
            try c.encode(text, forKey: .text)

        case .tool(let name, let summary, let result, let isError):
            try c.encode("tool", forKey: .kind)
            try c.encode(name, forKey: .toolName)
            try c.encode(summary, forKey: .toolSummary)
            try c.encodeIfPresent(result, forKey: .toolResult)
            try c.encode(isError, forKey: .isError)

        case .error(let message):
            try c.encode("error", forKey: .kind)
            try c.encode(message, forKey: .text)
        }
    }
}
