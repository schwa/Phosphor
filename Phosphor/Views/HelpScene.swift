#if os(macOS)
import SwiftUI

/// A minimal Help window, replacing the default (empty) help book. For now it's
/// a short text page with links to Metal references.
struct HelpScene: Scene {
    var body: some Scene {
        Window("Phosphor Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct HelpView: View {
    private static let metalSite = URL(string: "https://developer.apple.com/metal/")!
    private static let mslSpec = URL(string: "https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phosphor")
                .font(.largeTitle.bold())

            Text("Phosphor is a playground for Metal compute shaders. Write a kernel, see it render live, and use AI generation to create or edit shaders.")
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Metal references")
                .font(.headline)

            Link("Apple Metal developer site", destination: Self.metalSite)
            Link("Metal Shading Language Specification (PDF)", destination: Self.mslSpec)

            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 280, alignment: .topLeading)
    }
}

/// Menu item that opens the custom Help window, replacing the default help.
struct HelpCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Phosphor Help") {
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}

#Preview {
    HelpView()
}
#endif
