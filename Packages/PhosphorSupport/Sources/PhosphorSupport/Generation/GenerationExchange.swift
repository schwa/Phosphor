import Foundation

/// A complete record of one model turn — everything sent and received (#99).
///
/// Generation crosses the model boundary several times (optional plan turn,
/// the codegen turn, and up to one corrective retry). Each crossing is one
/// ``GenerationExchange``: the exact request prompt we sent, plus the decoded
/// response or the error. Because `@Generable` decodes structured content
/// directly, there is no raw response token stream to capture — the response
/// is the *decoded* value (serialized), or the decode/other error.
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
    /// The exact prompt string sent for this turn.
    public var request: String
    /// The decoded response, or `nil` if the turn errored.
    public var response: Response?
    /// The error string, or `nil` if the turn succeeded.
    public var error: String?
    public var startedAt: Date
    /// Seconds the turn took.
    public var elapsed: Double

    public init(
        kind: Kind, model: String, request: String,
        response: Response? = nil, error: String? = nil,
        startedAt: Date, elapsed: Double
    ) {
        self.kind = kind
        self.model = model
        self.request = request
        self.response = response
        self.error = error
        self.startedAt = startedAt
        self.elapsed = elapsed
    }
}
