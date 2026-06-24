#if os(macOS)
import PhosphorRuntime
import SwiftUI

/// The custom "About Phosphor" window, replacing the default AppKit panel.
struct AboutScene: Scene {
    var body: some Scene {
        Window("About Phosphor", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct AboutView: View {
    private static let repositoryURL = URL(string: "https://github.com/schwa/Phosphor")!

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    var body: some View {
        ZStack {
            PhosphorView(named: "About", bundle: .main)
                .accessibilityHidden(true)

            content
                .padding(40)
        }
        .frame(width: 420, height: 420)
        .background(.black)
    }

    private var content: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 6) {
                Text("Phosphor")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Write and preview Metal shaders")
                    .font(.headline)
                    .fontWeight(.regular)

                Text(versionString)
                    .font(.caption)
            }
            .multilineTextAlignment(.center)

            Link("github.com/schwa/Phosphor", destination: Self.repositoryURL)
                .font(.callout.weight(.medium))

            Text("© 2026 Jonathan Wight")
                .font(.caption2)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
        .padding(.vertical, 24)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: .rect(cornerRadius: 0)
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// Menu item that opens the custom About window, replacing the default
/// `.appInfo` command.
struct AboutCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Phosphor") {
            openWindow(id: "about")
        }
    }
}

#Preview {
    AboutView()
}
#endif
