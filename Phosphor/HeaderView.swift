import PhosphorSupport
import SwiftUI

/// Shows the synthesized `Phosphor.h` content for the current document's
/// environment. Presented from the toolbar as a popover.
struct HeaderView: View {
    let environment: PhosphorEnvironment

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            MetalSourceView(text: PhosphorHeader.source(for: environment))
                .padding(12)
        }
    }
}

#Preview("Header") {
    HeaderView(environment: PhosphorEnvironment(output: "image"))
}
