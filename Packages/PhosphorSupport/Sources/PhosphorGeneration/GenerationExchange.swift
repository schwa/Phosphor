import Foundation

/// A self-contained record of one model turn — everything sent, received, and
/// produced (#99).
///
/// Generation crosses the model boundary several times (optional plan turn,
/// the codegen turn, and up to one corrective retry). Each crossing is one
/// ``GenerationExchange``: the system ``instructions`` in effect, the exact
/// ``request`` we sent, the decoded ``response`` (or ``error``), and — for a
/// codegen turn — the assembled `.metal` ``producedSource`` we derived from
/// the response and wrote to the document. Together the exchanges are an exact,
/// non-duplicated log with all the data needed to debug a generation.
///
/// Because `@Generable` decodes structured content directly, there is no raw
/// response token stream to capture — the response is the *decoded* value
/// (serialized), or the decode/other error.
public struct GenerationExchange: Hashable, Sendable, Codable {
    /// Which kind of turn produced this exchange.
    public enum Kind: String, Hashable, Sendable, Codable {
        case plan
        case codegen
        case compileRetry
        case malformedRetry
    }

    /// The decoded response, when the turn succeeded. Exactly one of
    /// ``shader`` / ``approach`` is set per successful exchange.
    public struct Response: Hashable, Sendable, Codable {
        public var shader: GeneratedShader?
        public var approach: PlannedApproach?

        public init(shader: GeneratedShader? = nil, approach: PlannedApproach? = nil) {
            self.shader = shader
            self.approach = approach
        }
    }

    public var kind: Kind
    /// Backend display name (e.g. "Anthropic Claude Opus").
    public var model: String
    /// The system instructions in effect for this turn.
    public var instructions: String
    /// The exact prompt string sent for this turn.
    public var request: String
    /// The decoded response, or `nil` if the turn errored.
    public var response: Response?
    /// The error string, or `nil` if the turn succeeded.
    public var error: String?
    /// The assembled `.metal` source produced from the response and written to
    /// the document. Only set on a successful codegen turn; `nil` otherwise.
    public var producedSource: String?
    public var startedAt: Date
    /// Seconds the turn took.
    public var elapsed: Double

    public init(
        kind: Kind, model: String, instructions: String, request: String,
        response: Response? = nil, error: String? = nil, producedSource: String? = nil,
        startedAt: Date, elapsed: Double
    ) {
        self.kind = kind
        self.model = model
        self.instructions = instructions
        self.request = request
        self.response = response
        self.error = error
        self.producedSource = producedSource
        self.startedAt = startedAt
        self.elapsed = elapsed
    }
}
