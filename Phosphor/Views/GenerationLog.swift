import Foundation
import os
import PhosphorModel
import PhosphorCompile
import PhosphorGeneration
import PhosphorRuntime
import SwiftUI
import UniformTypeIdentifiers

/// On-disk record of a document's AI generation history (#99).
///
/// The model is nested: the log holds one ``Interaction`` per user submission;
/// each interaction holds the *work* — zero or more model request/response
/// ``GenerationExchange``s — plus the final outcome. This single structure is
/// the source of truth; the chat transcript is *derived* from it. It's
/// persisted (for saved docs), reloaded on reopen, and written verbatim by
/// "Export Transcript…". Versioned so the schema can evolve.
nonisolated struct GenerationLog: Codable, Hashable {
    /// On-disk schema version. Bump when the shape changes incompatibly.
    static let currentSchemaVersion = 3

    var schemaVersion: Int = currentSchemaVersion
    /// Stable key identifying which document/shader this log belongs to.
    var identity: String
    var createdAt: Date
    var updatedAt: Date
    /// One entry per user submission, oldest first.
    var interactions: [Interaction]

    init(identity: String, interactions: [Interaction] = []) {
        self.identity = identity
        self.createdAt = .now
        self.updatedAt = .now
        self.interactions = interactions
    }
}

/// One user submission and the work it produced (#99).
///
/// Just the user text plus the work: the ordered model request/response
/// ``GenerationExchange``s. Everything else is *derived* from the exchanges —
/// the plan (the plan exchange's response), the final shader + assembled
/// source (the last codegen exchange's response + `producedSource`), retries
/// (their own exchanges), and success/failure (the last exchange's outcome).
/// No duplicated fields: the exchanges are the exact log.
nonisolated struct Interaction: Codable, Hashable, Identifiable {
    var id = UUID()
    var startedAt: Date
    /// The user text that started this interaction.
    var prompt: String
    /// The document source at the moment this interaction started — the input
    /// state the model operated on (empty for a fresh generation). With
    /// ``finalSource`` (the output) this makes the interaction self-contained
    /// and reproducible without parsing the request (#99).
    var sourceBefore: String
    /// The work, oldest first.
    var exchanges: [GenerationExchange]

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, prompt, sourceBefore, exchanges
    }

    /// The plan, if a planning turn ran (derived from the plan exchange).
    var plan: PlannedApproach? {
        exchanges.first { $0.kind == .plan }?.response?.approach
    }

    /// The final assembled `.metal` source, if the interaction succeeded.
    var finalSource: String? {
        exchanges.last { $0.producedSource != nil }?.producedSource
    }

    /// The final shader title, if it succeeded.
    var finalTitle: String? {
        exchanges.last { $0.response?.shader != nil }?.response?.shader?.effectiveTitle
    }

    /// The terminal error, if the interaction failed (the last exchange errored
    /// and nothing usable was produced).
    var failureError: String? {
        guard finalSource == nil else { return nil }
        return exchanges.last?.error
    }
}

/// A `FileDocument` wrapper so a ``GenerationLog`` can be written out via
/// `.fileExporter`. Export is just the on-disk JSON (#99): same schema, same
/// encoder.
struct TranscriptDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    var log: GenerationLog

    init(log: GenerationLog) {
        self.log = log
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.log = try decoder.decode(GenerationLog.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(log))
    }
}

/// Reads and writes ``GenerationLog`` files under Application Support.
///
/// One JSON file per document identity:
///
///     ~/Library/Application Support/Phosphor/GenerationLogs/<hashed-identity>.json
///
/// Writes are best-effort and never throw into the UI — a logging tool must
/// not break generation.
enum GenerationLogStore {
    private static let logger = Logger(subsystem: "io.schwa.Phosphor", category: "generation-log")

    /// Directory holding all logs, created on demand. `nil` only if Application
    /// Support is unavailable (then logging silently no-ops).
    static var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base
            .appending(path: "Phosphor", directoryHint: .isDirectory)
            .appending(path: "GenerationLogs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File URL for a given identity (stable hash → filename).
    static func url(for identity: String) -> URL? {
        guard let directory else { return nil }
        let name = stableFilename(for: identity)
        return directory.appending(path: "\(name).json")
    }

    /// Loads the log for `identity`, or `nil` if none / unreadable.
    static func load(identity: String) -> GenerationLog? {
        guard let url = url(for: identity),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(GenerationLog.self, from: data)
        } catch {
            logger.error("failed to decode log for \(identity, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// Appends a completed ``Interaction`` for `identity` (#99). Best-effort.
    static func appendInteraction(identity: String, interaction: Interaction) {
        update(identity: identity) { $0.interactions.append(interaction) }
    }

    /// Loads (or creates) the log, applies `mutate`, and writes it back.
    /// Best-effort; failures are logged, not thrown.
    private static func update(identity: String, _ mutate: (inout GenerationLog) -> Void) {
        guard let url = url(for: identity) else { return }
        var log = load(identity: identity) ?? GenerationLog(identity: identity)
        mutate(&log)
        log.updatedAt = .now
        log.schemaVersion = GenerationLog.currentSchemaVersion
        do {
            let data = try encoder.encode(log)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("failed to write log for \(identity, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A filesystem-safe, stable filename derived from an arbitrary identity
    /// string (which may be a file path). Deterministic across launches
    /// (FNV-1a), so per-document logs are found again on relaunch.
    private static func stableFilename(for identity: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
