import Foundation

/// Structured diagnostic produced by parsing, validating, or compiling a
/// ``PhosphorConfiguration``.
///
/// Some diagnostics are fatal-for-the-configuration (parse + validation) — the
/// host shouldn't try to render anything. Others (per-pass compile errors)
/// are non-fatal — the affected pass is skipped and the rest of the
/// configuration keeps rendering.
public enum PhosphorDiagnostic: Hashable, Sendable {
    /// Front-matter TOML failed to parse.
    case frontMatterParse(String, line: Int?)
    /// A `Pass.TextureBinding` references a texture id that isn't declared
    /// in ``PhosphorConfiguration/textures``.
    case unknownResource(ResourceID, in: String)
    /// Two textures share the same id.
    case duplicateResource(ResourceID)
    /// Two passes share the same id (and thus kernel name).
    case duplicatePass(ResourceID)
    /// Two bindings on the same pass reference the same texture id.
    case duplicateBinding(name: String, in: ResourceID)
    /// A pass writes to a non-swap texture that it also reads. The result
    /// is undefined — the kernel could read either pre- or post-write
    /// pixels.
    case readWriteHazard(pass: ResourceID, resource: ResourceID)
    /// A pass declared no write-capable binding. It has nowhere to put
    /// its output.
    case passHasNoOutput(pass: ResourceID)
    /// The configuration's `output` doesn't refer to any declared texture.
    case missingOutput(ResourceID)
    /// A pass kernel failed to compile.
    case compile(PhosphorCompileError)
    /// A texture's `init = { kind = "image", file = "..." }` references an
    /// asset that wasn't supplied by the host. The texture is zero-filled
    /// as a fallback so the shader can still render.
    case missingAsset(name: String, in: ResourceID)
    /// An image-init texture is also declared ping-pong. A feedback buffer is
    /// overwritten every frame, so seeding it from an image is meaningless.
    case imageTextureCannotPingPong(ResourceID)
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
    /// Whether a diagnostic prevents rendering the configuration as a whole.
    public var isFatal: Bool {
        switch self {
        case .frontMatterParse,
             .unknownResource,
             .duplicateResource,
             .duplicatePass,
             .duplicateBinding,
             .readWriteHazard,
             .passHasNoOutput,
             .missingOutput,
             .imageTextureCannotPingPong:
            return true

        case .compile, .missingAsset:
            return false
        }
    }
}
