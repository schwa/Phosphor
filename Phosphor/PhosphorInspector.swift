import PhosphorSupport
import SwiftUI

/// Inspector pane for the editor. Shows live drawable size + pixel format
/// of the env's output texture.
struct PhosphorInspector: View {
    let parsed: ParsedPhosphorSource
    let runtime: PhosphorRuntime?

    var body: some View {
        Form {
            LabeledContent("Width", value: widthText)
            LabeledContent("Height", value: heightText)
            LabeledContent("Format", value: formatText)
        }
        .formStyle(.grouped)
    }

    private var widthText: String {
        if let runtime, runtime.currentDrawableSize.width > 0 {
            return "\(Int(runtime.currentDrawableSize.width)) px"
        }
        return "—"
    }

    private var heightText: String {
        if let runtime, runtime.currentDrawableSize.height > 0 {
            return "\(Int(runtime.currentDrawableSize.height)) px"
        }
        return "—"
    }

    private var formatText: String {
        guard let environment = parsed.environment,
              let outputTexture = environment.textures.first(where: { $0.id == environment.output }) else {
            return "—"
        }
        return outputTexture.format.rawValue
    }
}
