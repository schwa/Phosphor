import Foundation

/// Fraction of the drawable resolution the shader pipeline renders at.
///
/// Anything below `.native` renders offscreen and is MetalFX-upscaled to the
/// drawable, trading detail for frame rate on expensive shaders.
enum RenderScale: String, CaseIterable, Identifiable, Sendable {
    case native
    case threeQuarters
    case twoThirds
    case half

    var id: String { rawValue }

    var factor: Double {
        switch self {
        case .native: return 1
        case .threeQuarters: return 0.75
        case .twoThirds: return 2.0 / 3.0
        case .half: return 0.5
        }
    }

    var title: String {
        switch self {
        case .native: return "Native"
        case .threeQuarters: return "75% (Upscaled)"
        case .twoThirds: return "67% (Upscaled)"
        case .half: return "50% (Upscaled)"
        }
    }
}
