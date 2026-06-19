import SwiftUI

/// SwiftUI environment key carrying the app's shared ``AudioCaptureEngine``.
///
/// Set once at the app root (e.g. `.environment(\.audioCapture, ...)`); read
/// by ``PhosphorView`` to wire the engine into its ``PhosphorRuntime``, and
/// by any toolbar / settings UI that needs to drive the enabled state.
public extension EnvironmentValues {
    @Entry var audioCapture: AudioCaptureEngine?
}
