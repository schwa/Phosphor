import Foundation
import PhosphorSupport

/// One entry in the generation chat transcript: either a user prompt or the
/// model's response to it.
///
/// The transcript is in-memory for the session (durable per-version storage
/// is tracked separately). Prior *user* prompts embedded in the source are
/// re-hydrated on appear via `PromptHistory.extract` so some history survives
/// reopen, even though responses don't.
struct GenerationTurn: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        /// A successful generation; `title` is the model-provided effect name.
        case assistant(title: String)
        /// A failed generation; `text` carries the error message.
        case error
    }

    let id = UUID()
    let role: Role
    let text: String
    /// Errors that were auto-corrected on the way to this (successful) turn.
    /// Kept so the failure survives the correction (#96); empty otherwise.
    var corrections: [GenerationCorrection] = []

    static func user(_ prompt: String) -> Self {
        GenerationTurn(role: .user, text: prompt)
    }

    static func assistant(title: String, summary: String, corrections: [GenerationCorrection] = []) -> Self {
        GenerationTurn(role: .assistant(title: title), text: summary, corrections: corrections)
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
    }

    let stage: Stage
    /// Which attempt this is (1 = first, 2 = the retry).
    let attempt: Int
    /// Compiler error feedback, present only when retrying.
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
