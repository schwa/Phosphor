// `read()`/`write(_:)` are `throws` to satisfy CollaborationKit's
// `TextDocument` protocol even though this adapter's closures don't throw.
// `@preconcurrency` on the Sendable conformance is a compiler no-op here, so
// the incompatible_concurrency_annotation rule is suppressed instead.
// swiftlint:disable unneeded_throws_rethrows incompatible_concurrency_annotation

import CollaborationKit
import Foundation

/// A ``CollaborationKit/TextDocument`` over a single live `.metal` source
/// string, used as the shared backing for the conversational shader tools.
///
/// The whole `.metal` source — body *and* front-matter — is the single source
/// of truth; all four shader tools operate on this one document so they can't
/// drift from each other.
///
/// The document owns a thread-safe internal buffer so the tools (which run on
/// CollaborationKit's cooperative tool-loop threads, **not** the main actor)
/// can read and write synchronously without any actor hop. The host:
///
/// - seeds the buffer before a turn with ``setSource(_:)``, and
/// - observes model edits via the ``onWrite`` callback (delivered on the
///   tool-loop thread; the host is responsible for hopping to the main actor
///   to push the new text into its editor).
public final class MetalSourceDocument: TextDocument, @unchecked Sendable {
    private let storage: Storage
    private let writeObserver: (@Sendable (String) -> Void)?

    /// Creates a document seeded with `source`.
    ///
    /// - Parameters:
    ///   - source: The initial full `.metal` source.
    ///   - onWrite: Called after every model write with the new full source.
    ///     Delivered off the main actor; hop yourself to update UI.
    public init(source: String = "", onWrite: (@Sendable (String) -> Void)? = nil) {
        self.storage = Storage(source)
        self.writeObserver = onWrite
    }

    /// Creates an in-memory document for tests and previews.
    public convenience init(inMemory source: String = "") {
        self.init(source: source, onWrite: nil)
    }

    /// Replaces the buffer contents from the host (e.g. to seed the live editor
    /// text before a turn). Does **not** fire ``onWrite``.
    public func setSource(_ text: String) {
        storage.value = text
    }

    public func read() throws -> String {
        storage.value
    }

    public func write(_ text: String) throws {
        storage.value = text
        writeObserver?(text)
    }
}

private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) {
        self.storage = value
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}
