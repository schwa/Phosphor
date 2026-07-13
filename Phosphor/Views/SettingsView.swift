import CollaborationKit
import CollaborationKitUI
import SwiftUI

/// Top-level Settings scene content: CollaborationKit's built-in settings pane
/// (backend picker, credential section for the current backend, model picker).
///
/// Historically Phosphor had its own hand-rolled clone of this. See #139.
struct SettingsView: View {
    var body: some View {
        CollaborationSettingsView()
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(
            CollaborationCredentials(
                store: KeychainCredentialStore(service: PhosphorBackends.keychainService),
                backends: PhosphorBackends.all,
                defaultsKey: PhosphorBackends.backendDefaultsKey
            )
        )
}
