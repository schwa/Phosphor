import PhosphorModel
import PhosphorCompile
import PhosphorGeneration
import PhosphorRuntime
import SwiftUI

/// Dropdown that lets the user pick which resource the preview should
/// blit to the drawable. "Output" (nil) follows the configuration's declared
/// output; other choices are individual texture resources. Disabled when
/// the configuration has only one resource (or none).
struct ResourcePickerView: View {
    let configuration: PhosphorConfiguration
    @Binding var displayedResource: ResourceID?

    private var resourceIDs: [ResourceID] {
        configuration.textures.map(\.id)
    }

    private var isDisabled: Bool {
        resourceIDs.count < 2
    }

    var body: some View {
        Picker("Preview", selection: $displayedResource) {
            Text("Output (\(configuration.output.raw))").tag(ResourceID?.none)
            Divider()
            ForEach(resourceIDs, id: \.self) { id in
                Text(id.raw).tag(Optional(id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 180)
        .disabled(isDisabled)
        .help(isDisabled
                ? "Only one resource declared—nothing to switch to"
                : "Preview a specific resource instead of the declared output")
    }
}

#Preview("Resource picker") {
    ResourcePickerView(
        configuration: PhosphorConfiguration(output: "image"),
        displayedResource: .constant(nil)
    )
    .padding()
}
