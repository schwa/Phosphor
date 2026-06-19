import PhosphorSupport
import SwiftUI

@main
struct PhosphorApp: App {
    @State private var audioCapture = AudioCaptureEngine()
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false

    var body: some Scene {
        DocumentGroup { document in
            PhosphorDocumentView(document: document)
                .environment(\.audioCapture, audioCapture)
                .onAppear { syncMicState() }
        } makeDocument: { configuration, _ in
            PhosphorMetalDocument(configuration: configuration)
        }

        Settings {
            SettingsView()
        }
    }

    /// Pushes the persisted toggle state into the engine on app launch and
    /// after any change. The engine handles permission-prompt on enable.
    private func syncMicState() {
        if micEnabled != audioCapture.isEnabled {
            audioCapture.isEnabled = micEnabled
        }
    }
}
