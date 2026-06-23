import Foundation

/// Canonical starter shader for brand-new documents.
///
/// One source of truth shared by ``PhosphorMetalDocument`` and the
/// `.phosphord` bundle document so both doc types open at the same
/// hello-world. Also used by the Generate panel as the "untouched
/// template" sentinel for switching between fresh-generation and
/// modify-existing flows.
public enum PhosphorStarterTemplate {
    /// The starter shader source, loaded from the bundled
    /// `Resources/StarterTemplate.metal` (single source of truth), cached
    /// after first read. A missing/unreadable resource is a build error, so
    /// it traps rather than limping along with bad content.
    public static let source: String = {
        guard let url = Bundle.module.url(forResource: "StarterTemplate", withExtension: "metal") else {
            fatalError("Missing bundled resource StarterTemplate.metal")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read StarterTemplate.metal: \(error)")
        }
    }()
}
