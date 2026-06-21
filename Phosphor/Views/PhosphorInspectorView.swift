import PhosphorSupport
import SwiftUI

/// Inspector pane for the editor. Wraps tab-style sections; currently just
/// one tab ("Output") showing drawable size + pixel format.
struct PhosphorInspectorView: View {
    let parsed: ParsedPhosphorSource
    let runtime: PhosphorRuntime
    @Binding var text: String

    var body: some View {
        TabView {
            Tab("Output", systemImage: "rectangle.dashed") {
                OutputTab(parsed: parsed, runtime: runtime)
            }
            Tab("Configuration", systemImage: "slider.horizontal.below.rectangle") {
                PhosphorConfigurationEditorView(parsed: parsed, text: $text)
            }
        }
    }
}

/// Output tab: live drawable size + pixel format of the config's output
/// texture.
private struct OutputTab: View {
    let parsed: ParsedPhosphorSource
    let runtime: PhosphorRuntime

    var body: some View {
        Form {
            LabeledContent("Width", value: widthText)
            LabeledContent("Height", value: heightText)
            LabeledContent("Format", value: formatText)
        }
        .formStyle(.grouped)
    }

    private var widthText: String {
        runtime.currentDrawableSize.width > 0 ? "\(Int(runtime.currentDrawableSize.width)) px" : "—"
    }

    private var heightText: String {
        runtime.currentDrawableSize.height > 0 ? "\(Int(runtime.currentDrawableSize.height)) px" : "—"
    }

    private var formatText: String {
        guard let configuration = parsed.configuration,
              let outputTexture = configuration.textures.first(where: { $0.id == configuration.output }) else {
            return "—"
        }
        return outputTexture.format.rawValue
    }
}
