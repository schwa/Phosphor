import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

/// On-disk record of a document's AI generation transcript (#99).
///
/// The JSON log is the single source of truth: the chat transcript is mirrored
/// to disk as it changes, reloaded when the panel reopens, and "Export
/// Transcript…" simply writes this same JSON out. Versioned so the schema can
/// evolve.
nonisolated struct GenerationLog: Codable, Hashable {
    /// On-disk schema version. Bump when the shape changes incompatibly.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    /// Stable key identifying which document/shader this log belongs to.
    var identity: String
    /// When the log was first created.
    var createdAt: Date
    /// When it was last written.
    var updatedAt: Date
    /// The transcript, oldest first.
    var turns: [GenerationTurn]

    init(identity: String, turns: [GenerationTurn] = []) {
        self.identity = identity
        self.createdAt = .now
        self.updatedAt = .now
        self.turns = turns
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

    /// Writes `turns` for `identity`, merging into any existing log's metadata.
    /// Best-effort; failures are logged, not thrown.
    static func save(identity: String, turns: [GenerationTurn]) {
        guard let url = url(for: identity) else { return }
        var log = load(identity: identity) ?? GenerationLog(identity: identity)
        log.turns = turns
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
