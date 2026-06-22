import PhosphorSupport
import SwiftUI

/// Tabs available in the editor inspector.
enum InspectorTab: String, Hashable {
    case output
    case configuration
    case generate
}

/// Inspector pane for the editor: Output (drawable size / format),
/// Configuration (front-matter editor), and Generate (AI panel).
struct PhosphorInspectorView: View {
    let parsed: ParsedPhosphorSource
    @Binding var text: String
    let isUntouchedTemplate: Bool
    let onTextChange: () -> Void
    @Binding var selection: InspectorTab
    var onGeneratingChange: (Bool) -> Void = { _ in }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Output", systemImage: "rectangle.dashed", value: InspectorTab.output) {
                OutputTab(parsed: parsed)
            }
            Tab("Configuration", systemImage: "slider.horizontal.below.rectangle", value: InspectorTab.configuration) {
                PhosphorConfigurationEditorView(parsed: parsed, text: $text)
            }
            Tab("Generate", systemImage: "sparkles", value: InspectorTab.generate) {
                ScrollView {
                    GeneratePanel(
                        text: $text,
                        parsed: parsed,
                        isUntouchedTemplate: isUntouchedTemplate,
                        onTextChange: onTextChange,
                        onGeneratingChange: onGeneratingChange
                    )
                }
            }
        }
    }
}

/// Output tab: live drawable size + pixel format of the config's output
/// texture.
private struct OutputTab: View {
    let parsed: ParsedPhosphorSource
    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime

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
        let configuration = parsed.configuration
        guard let outputTexture = configuration.textures.first(where: { $0.id == configuration.output }) else {
            return "—"
        }
        return outputTexture.format.rawValue
    }
}
