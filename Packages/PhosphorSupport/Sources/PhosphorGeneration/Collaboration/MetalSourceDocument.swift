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
/// The host owns the actual editor buffer; this adapter bridges reads and
/// writes through two closures so a model edit lands wherever the host wants
/// (e.g. an undoable `TextMutator.apply`). The whole `.metal` source — body
/// *and* front-matter — is the single source of truth; all four shader tools
/// operate on this one document so they can't drift from each other.
///
/// Both closures are `@Sendable`; the host is responsible for hopping to the
/// main actor if its buffer requires it.
public final class MetalSourceDocument: TextDocument, @unchecked Sendable {
    private let reader: @Sendable () -> String
    private let writer: @Sendable (String) -> Void

    /// Creates a document backed by host-supplied read/write closures.
    ///
    /// - Parameters:
    ///   - read: Returns the current full `.metal` source.
    ///   - write: Replaces the full `.metal` source (e.g. via `TextMutator`).
    public init(read: @escaping @Sendable () -> String, write: @escaping @Sendable (String) -> Void) {
        self.reader = read
        self.writer = write
    }

    /// Creates an in-memory document seeded with `source`, for tests and
    /// previews. Mutations are kept in a thread-safe local buffer.
    public convenience init(inMemory source: String = "") {
        let storage = Storage(source)
        self.init(read: { storage.value }, write: { storage.value = $0 })
    }

    public func read() throws -> String {
        reader()
    }

    public func write(_ text: String) throws {
        writer(text)
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
