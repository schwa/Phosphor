#if canImport(AppKit)
import AppKit
#endif
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhosphorApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var audioCapture = AudioCaptureEngine()
    @AppStorage("phosphor.audio.micEnabled") private var micEnabled: Bool = false

    var body: some Scene {
        #if os(macOS)
        SplashScene()
        #endif

        DocumentGroup { document in
            PhosphorDocumentView(document: document)
                .environment(audioCapture)
                .onAppear { syncMicState() }
        } makeDocument: { configuration, _ in
            PhosphorMetalDocument(configuration: configuration)
        }
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) {
                MyNewDocumentButton(title: "New Metal Shader", contentType: .metalSource)
                    .keyboardShortcut("n", modifiers: .command)
                MyNewDocumentButton(title: "New Phosphor Bundle", contentType: .phosphorBundle)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            #endif
            CommandGroup(after: .pasteboard) {
                ReformatFrontMatterButton()
            }
            #if DEBUG
            DebugCommands()
            #endif
        }

        DocumentGroup { document in
            PhosphorBundleDocumentView(document: document)
                .environment(audioCapture)
                .onAppear { syncMicState() }
        } makeDocument: { configuration, _ in
            PhosphorBundleDocument(configuration: configuration)
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    /// Pushes the persisted toggle state into the engine on app launch and
    /// after any change. The engine handles permission-prompt on enable.
    private func syncMicState() {
        if micEnabled != audioCapture.isEnabled {
            audioCapture.isEnabled = micEnabled
        }
    }
}

/// Coordinates the Welcome/splash window with the document system:
///
/// - Suppresses the default "open an untitled document on launch" behaviour so
///   the splash window is what the user sees first.
/// - Re-shows the splash window when the app is reopened with no visible
///   windows (e.g. clicking the Dock icon), and after the last document window
///   closes.
#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_: Notification) {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowClose(notification)
        }
    }

    /// Prevent AppKit from opening a blank untitled document at launch; the
    /// splash window takes that role.
    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSplashWindow()
        }
        return true
    }

    private func handleWindowClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }
        // Only react to document windows closing.
        guard NSDocumentController.shared.document(for: closingWindow) != nil else {
            return
        }
        // `willClose` fires before the window leaves `NSApp.windows`, so exclude
        // the window that is closing when counting remaining document windows.
        let remainingDocumentWindows = NSApp.windows.contains { window in
            window !== closingWindow &&
                window.isVisible &&
                NSDocumentController.shared.document(for: window) != nil
        }
        if !remainingDocumentWindows {
            showSplashWindow()
        }
    }

    private func showSplashWindow() {
        if let splashWindow = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("splash") == true }) {
            splashWindow.makeKeyAndOrderFront(nil)
        }
    }
}
#endif
