import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
struct SplashScene: Scene {
    var body: some Scene {
        Window("Welcome", id: "splash") {
            SplashView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

struct SplashView: View {
    @Environment(\.openDocument)
    private var openDocument

    @Environment(\.dismissWindow)
    private var dismissWindow

    @State
    private var selectedURL: URL?

    @State
    private var isFileImporterPresented = false

    private var recentDocumentURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    private var readableContentTypes: [UTType] {
        PhosphorMetalDocument.readableContentTypes + PhosphorBundleDocument.readableContentTypes
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel - branding and actions
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 20) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .accessibilityHidden(true)

                    Text("Phosphor")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("Write and preview Metal shaders")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        openUntitledDocument(ofType: .metalSource)
                        dismissWindow(id: "splash")
                    } label: {
                        Label("New Metal Shader", systemImage: "doc.badge.plus")
                            .frame(width: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Open File…", systemImage: "folder")
                            .frame(width: 160)
                    }
                    .controlSize(.large)
                    .fileImporter(
                        isPresented: $isFileImporterPresented,
                        allowedContentTypes: readableContentTypes,
                        allowsMultipleSelection: false
                    ) { result in
                        if case let .success(urls) = result, let url = urls.first {
                            guard url.startAccessingSecurityScopedResource() else {
                                return
                            }
                            openFile(at: url)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .frame(width: 240)
            .background(.ultraThinMaterial)

            // Right panel - recent documents
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Documents")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                Divider()

                if recentDocumentURLs.isEmpty {
                    ContentUnavailableView {
                        Label("No Recent Documents", systemImage: "clock")
                    } description: {
                        Text("Documents you open will appear here")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedURL) {
                        ForEach(Array(recentDocumentURLs.enumerated()), id: \.element) { index, url in
                            RecentDocumentRow(url: url, index: index)
                                .tag(url)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 12))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 0)
                    .onChange(of: selectedURL) { _, newValue in
                        if let url = newValue {
                            openFile(at: url)
                        }
                    }
                }
            }
            .frame(width: 360)
            .background(.background)
        }
        .frame(width: 600, height: 400)
    }

    private func openUntitledDocument(ofType contentType: UTType) {
        let controller = NSDocumentController.shared
        do {
            let document = try controller.makeUntitledDocument(ofType: contentType.identifier)
            controller.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }

    private func openFile(at url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: "splash")
            } catch {
                // Document open failed - system will show alert
            }
        }
    }
}

struct RecentDocumentRow: View {
    let url: URL
    let index: Int

    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityLabel(Text("File: \(url.deletingPathExtension().lastPathComponent)"))

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.body)
                    .lineLimit(1)

                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .modifier(KeyboardShortcutModifier(index: index))
    }
}

struct KeyboardShortcutModifier: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

#Preview {
    SplashView()
}
#endif
