import Foundation

/// Structured diagnostic produced by parsing, validating, or compiling a
/// ``PhosphorEnvironment``.
///
/// Some diagnostics are fatal-for-the-environment (parse + validation) — the
/// host shouldn't try to render anything. Others (per-pass compile errors)
/// are non-fatal — the affected pass is skipped and the rest of the
/// environment keeps rendering.
public enum PhosphorDiagnostic: Hashable, Sendable {
    /// Front-matter TOML failed to parse.
    case frontMatterParse(String, line: Int?)
    /// A `Pass.Input` or `Pass.output` or `Environment.output` references a
    /// resource ID that isn't declared in ``PhosphorEnvironment/resources``.
    case unknownResource(ResourceID, in: String)
    /// Two resources share the same ID.
    case duplicateResource(ResourceID)
    /// Two passes share the same ID (and thus kernel name).
    case duplicatePass(ResourceID)
    /// A binding name isn't of the form `iChannelN`.
    case unknownChannelName(String, in: ResourceID)
    /// A binding references a channel index >= the inferred channel count.
    /// Only emitted if the index is something other than what would set the
    /// count (so e.g. duplicate iChannel0 bindings catch as `duplicateBinding`).
    case channelOutOfRange(name: String, inferred: Int)
    /// Two bindings on the same pass use the same channel name.
    case duplicateBinding(name: String, in: ResourceID)
    /// A pass writes to a non-ping-pong resource that it also reads.
    case readWriteHazard(pass: ResourceID, resource: ResourceID)
    /// The environment's `output` doesn't refer to any declared resource.
    case missingOutput(ResourceID)
    /// A pass kernel failed to compile.
    case compile(PhosphorCompileError)
    /// A texture resource references an image asset by name, but no asset
    /// with that name was supplied by the host. The texture is zero-filled
    /// as a fallback so the shader can still render.
    case missingAsset(name: String, in: ResourceID)
}

/// Compile error for one pass's kernel.
public struct PhosphorCompileError: Hashable, Sendable {
    public var passID: ResourceID
    public var rawError: String

    public init(passID: ResourceID, rawError: String) {
        self.passID = passID
        self.rawError = rawError
    }
}

extension PhosphorDiagnostic {
    /// Whether a diagnostic prevents rendering the environment as a whole.
    public var isFatal: Bool {
        switch self {
        case .frontMatterParse,
             .unknownResource,
             .duplicateResource,
             .duplicatePass,
             .unknownChannelName,
             .channelOutOfRange,
             .duplicateBinding,
             .readWriteHazard,
             .missingOutput:
            return true

        case .compile, .missingAsset:
            return false
        }
    }
}
