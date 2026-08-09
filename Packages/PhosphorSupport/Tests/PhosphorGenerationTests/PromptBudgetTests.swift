import Foundation
@testable import PhosphorGeneration
import Testing

/// Guards the size of the static system prompt (#133).
///
/// The generation session is long-running and stateful, so this text is
/// re-sent on every single turn — it's the dominant fixed token cost of a
/// conversation, paid again for each message. Without a ceiling it grows
/// silently, one well-meaning clarification at a time.
@Suite("System prompt budget")
struct PromptBudgetTests {
    /// Rough token estimate. Real tokenisers differ, but ~4 characters per
    /// token tracks English prose plus code closely enough to hold a budget.
    static func estimatedTokens(_ text: String) -> Int {
        text.count / 4
    }

    /// Measured at 3,681 tokens after the #133 de-duplication pass. The
    /// headroom is for genuinely new guidance; if you need more than this,
    /// cut something first — or move it into a tool description, which is
    /// only sent when the tool is relevant.
    static let conversationalBudget = 4_000

    @Test("The conversational system prompt stays within budget")
    func withinBudget() {
        let tokens = Self.estimatedTokens(GeneratorInstructions.conversationalInstructions)
        #expect(
            tokens <= Self.conversationalBudget,
            "system prompt is ~\(tokens) tokens, budget is \(Self.conversationalBudget)"
        )
    }

    /// The helper interface is derived from `Phosphor.h` at runtime, so it
    /// grows whenever a helper is added. Worth knowing about separately from
    /// the hand-written prose.
    @Test("The helper interface stays a small fraction of the prompt")
    func interfaceIsSmall() {
        let interface = Self.estimatedTokens(PhosphorInterface.source)
        let total = Self.estimatedTokens(GeneratorInstructions.conversationalInstructions)
        #expect(interface * 4 < total, "interface is ~\(interface) of ~\(total) tokens")
    }

    /// Each instruction should appear once. "Read before you edit" was
    /// previously stated four times across the prompt, which is the kind of
    /// repetition that makes the prompt expensive without making it clearer.
    @Test("Tool-loop guidance doesn't repeat itself")
    func noRepeatedGuidance() {
        let prompt = GeneratorInstructions.conversationalInstructions.lowercased()
        let readBeforeEdit = prompt.ranges(of: "read before").count
            + prompt.ranges(of: "`read` before").count
        #expect(readBeforeEdit <= 1, "'read before edit' is stated \(readBeforeEdit) times")
    }
}
