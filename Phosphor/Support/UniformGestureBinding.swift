import PhosphorCompile
import PhosphorModel

/// Maps the render surface's four gesture channels onto gesture-bound `.float`
/// uniforms, writing results into a `[String: UniformValue]` store.
///
/// Each channel produces a normalized scalar; this maps it into the bound
/// uniform's slider range (or `0...1` when it has no slider) and clamps.
/// Channels with no bound uniform are ignored. See `UniformDecl.gesture`.
enum UniformGestureBinding {
    /// The uniform (name + slider range) bound to each gesture channel in
    /// `configuration`, if any.
    struct Bindings {
        var byChannel: [UniformGesture: (name: String, range: ClosedRange<Float>)] = [:]

        var isEmpty: Bool { byChannel.isEmpty }

        func uniform(for channel: UniformGesture) -> (name: String, range: ClosedRange<Float>)? {
            byChannel[channel]
        }
    }

    /// Builds the channel→uniform map for a configuration. Assumes the config
    /// validated (one uniform per channel; gestures only on `.float`).
    static func bindings(for configuration: PhosphorConfiguration) -> Bindings {
        var result = Bindings()
        for uniform in configuration.uniforms {
            guard let channel = uniform.gesture, uniform.kind == .float else { continue }
            result.byChannel[channel] = (uniform.name, sliderRange(for: uniform))
        }
        return result
    }

    /// Writes `normalized` (0...1) into the uniform bound to `channel`, mapped
    /// into that uniform's range. No-op if nothing is bound.
    static func apply(
        normalized: Float,
        channel: UniformGesture,
        bindings: Bindings,
        into values: inout [String: UniformValue]
    ) {
        guard let bound = bindings.uniform(for: channel) else { return }
        let clamped = min(max(normalized, 0), 1)
        let mapped = bound.range.lowerBound + clamped * (bound.range.upperBound - bound.range.lowerBound)
        values[bound.name] = .float(mapped)
    }

    /// The slider range declared on a uniform, or `0...1` if it has none.
    private static func sliderRange(for uniform: UniformDecl) -> ClosedRange<Float> {
        if case .slider(let lo, let hi) = uniform.ui, hi > lo {
            return lo...hi
        }
        return 0...1
    }
}
