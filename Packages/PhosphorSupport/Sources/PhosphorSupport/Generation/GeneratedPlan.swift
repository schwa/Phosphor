import Foundation
import FoundationModels

/// High-level shape of a planned effect. The one structured field on a plan;
/// a cheap, reliable scaffolding hint for the codegen turn (e.g. `feedback`
/// tells codegen to build ping-pong front-matter).
@Generable
public enum PlanShape: String, Sendable {
    /// A single compute pass writing one output texture.
    case singlePassImage
    /// Several passes in sequence (intermediate buffers).
    case multiPass
    /// A pass that reads and writes the same resource (ping-pong / simulation).
    case feedback
}

/// The model-produced portion of a generation plan: a one-line intent, the
/// structural shape, and freeform prose describing the approach.
///
/// Deliberately mostly textual — the model reasons in prose (build steps,
/// Shadertoy→Phosphor mapping, edge-case decisions); only ``shape`` is
/// structured. The verbatim request (prompt + pasted source) is NOT part of
/// this schema; it's attached host-side in ``GeneratedPlan`` so the model
/// never has to echo it back (and can't truncate it).
@Generable
public struct PlannedApproach: Sendable {
    @Guide(description: "One-line summary of the effect to build, e.g. 'falling rain streaks over a dark background'.")
    var intent: String

    @Guide(description: "The structural shape: 'singlePassImage' for one kernel writing one texture; 'multiPass' for several sequential passes; 'feedback' for a ping-pong simulation that reads and writes the same texture.")
    var shape: PlanShape

    @Guide(description: "Freeform plan prose: the approach, ordered build steps, and — when porting pasted code — the GLSL/Shadertoy → Phosphor MSL mapping (iTime→uniforms.time, fragCoord→gid, mainImage→kernel void image, texture(iChannelN,uv)→textures.<id>.read(gid), etc.). Note edge-case decisions (wrap vs. clamp, pixel format). Do NOT write Metal kernel code here — that's the next step.")
    var plan: String
}

/// A full generation plan: the model's ``PlannedApproach`` plus the verbatim
/// request it was planning for. The request fields are attached host-side
/// (never round-tripped through the model) so the original prompt and any
/// pasted source are preserved exactly and can drive the codegen turn.
public struct GeneratedPlan: Hashable, Sendable {
    /// One-line intent (from the model).
    public let intent: String
    /// Structural shape (from the model).
    public let shape: PlanShape
    /// Freeform approach prose (from the model).
    public let plan: String
    /// The user's full prompt, verbatim.
    public let originalPrompt: String
    /// Any pasted source (Shadertoy GLSL / MSL) the request included, verbatim.
    /// Empty when the request was a plain description.
    public let sourceCode: String

    public init(approach: PlannedApproach, originalPrompt: String, sourceCode: String) {
        self.intent = approach.intent
        self.shape = approach.shape
        self.plan = approach.plan
        self.originalPrompt = originalPrompt
        self.sourceCode = sourceCode
    }
}

public extension PlannedApproach {
    /// Public read access to the model's plan fields (members are internal).
    var planIntent: String { intent }
    var planShape: PlanShape { shape }
    var planBody: String { plan }
}

extension PlanShape: Hashable {}
extension PlanShape: Codable {}
extension PlannedApproach: Codable, Hashable {}
extension GeneratedPlan: Codable {}

public extension PlanShape {
    /// Human-readable label for UI (e.g. the transcript plan bubble).
    var displayName: String {
        switch self {
        case .singlePassImage: "Single pass"
        case .multiPass: "Multi-pass"
        case .feedback: "Feedback"
        }
    }
}
