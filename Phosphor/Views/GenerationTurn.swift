import Foundation
import PhosphorSupport

/// One entry in the generation chat transcript: either a user prompt or the
/// model's response to it.
///
/// The transcript is in-memory for the session (durable per-version storage
/// is tracked separately). Prior *user* prompts embedded in the source are
/// re-hydrated on appear via `PromptHistory.extract` so some history survives
/// reopen, even though responses don't.
nonisolated struct GenerationTurn: Identifiable, Hashable, Codable {
    /// Why a recoverable retry happened.
    enum RetryKind: Hashable, Codable {
        case compile
        case malformed
    }

    enum Role: Hashable, Codable {
        case user
        /// The planning turn (#74): the model's approach before codegen.
        /// `intent` and `shape` head the bubble; `text` holds the prose.
        case plan(intent: String, shape: String)
        /// A successful generation; `title` is the model-provided effect name.
        case assistant(title: String)
        /// A recoverable failure (the first attempt didn't compile, or its
        /// response was malformed) that the generator is auto-correcting.
        /// Shown as its own turn so the failure and the fix are two distinct
        /// messages (#94/#96), then followed by the successful `assistant`
        /// turn. `text` carries the error.
        case retried(RetryKind)
        /// A terminal failure; `text` carries the error message.
        case error
    }

    var id = UUID()
    let role: Role
    let text: String
    /// When this turn was recorded. Defaults to now for live turns.
    var timestamp: Date = .now

    private enum CodingKeys: String, CodingKey { case id, role, text, timestamp }

    static func user(_ prompt: String) -> Self {
        GenerationTurn(role: .user, text: prompt)
    }

    static func plan(intent: String, shape: String, body: String) -> Self {
        GenerationTurn(role: .plan(intent: intent, shape: shape), text: body)
    }

    static func assistant(title: String, summary: String) -> Self {
        GenerationTurn(role: .assistant(title: title), text: summary)
    }

    static func retried(_ errorText: String, kind: RetryKind) -> Self {
        GenerationTurn(role: .retried(kind), text: errorText)
    }

    static func error(_ message: String) -> Self {
        GenerationTurn(role: .error, text: message)
    }
}

/// In-flight status shown in the transcript while a generation runs.
/// Carries enough context to explain *why* a retry is happening, including
/// the actual Metal compiler error fed back to the model.
struct GenerationStatus: Hashable {
    enum Stage: Hashable {
        case generating
        case retrying
        case retryingMalformed
        case planning
    }

    let stage: Stage
    /// Which attempt this is (1 = first, 2 = the retry).
    let attempt: Int
    /// Error feedback (compiler or decode), present only when retrying.
    let compileError: String?
    /// True when the request modifies an existing shader (its source is sent
    /// to the model); false for a fresh generation.
    let isModifying: Bool
    /// Byte count of the source sent along on a modify request.
    let sourceByteCount: Int

    static func generating(attempt: Int, isModifying: Bool = false, sourceByteCount: Int = 0) -> Self {
        GenerationStatus(stage: .generating, attempt: attempt, compileError: nil, isModifying: isModifying, sourceByteCount: sourceByteCount)
    }

    init(stage: Stage, attempt: Int, compileError: String?, isModifying: Bool = false, sourceByteCount: Int = 0) {
        self.stage = stage
        self.attempt = attempt
        self.compileError = compileError
        self.isModifying = isModifying
        self.sourceByteCount = sourceByteCount
    }

    /// Maps a generator phase to a UI status, carrying mode context forward.
    init(phase: GenerationPhase, isModifying: Bool, sourceByteCount: Int) {
        switch phase {
        case .generating:
            self = .generating(attempt: 1, isModifying: isModifying, sourceByteCount: sourceByteCount)

        case .retrying(let compileError):
            self = GenerationStatus(stage: .retrying, attempt: 2, compileError: compileError, isModifying: isModifying, sourceByteCount: sourceByteCount)

        case .retryingMalformed(let decodeError):
            self = GenerationStatus(stage: .retryingMalformed, attempt: 2, compileError: decodeError, isModifying: isModifying, sourceByteCount: sourceByteCount)

        case .planning:
            self = GenerationStatus(stage: .planning, attempt: 1, compileError: nil, isModifying: isModifying, sourceByteCount: sourceByteCount)

        case .planned:
            // Reported as its own transcript turn; show generating next.
            self = .generating(attempt: 1, isModifying: isModifying, sourceByteCount: sourceByteCount)
        }
    }

    var headline: String {
        switch stage {
        case .generating:
            if isModifying {
                return "Modifying current shader (\(byteSummary) of source sent)…"
            }
            return "Generating a new shader from scratch…"

        case .retrying:
            return "First attempt didn’t compile — sending the errors back and retrying…"

        case .retryingMalformed:
            return "First response was malformed — asking the model to resend a complete one…"

        case .planning:
            return "Planning the approach…"
        }
    }

    private var byteSummary: String {
        let bytes = Double(sourceByteCount)
        if bytes >= 1024 {
            return String(format: "%.1f KB", bytes / 1024)
        }
        return "\(sourceByteCount) bytes"
    }

    /// Secondary, monospaced detail line (the compiler errors), if any.
    var detail: String? {
        guard let compileError, !compileError.isEmpty else { return nil }
        return compileError
    }
}
