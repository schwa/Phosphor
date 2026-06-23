import Foundation
import os

/// Registry of textures shipped inside the framework and always available to
/// any shader, with no import step.
///
/// Built-ins live under a reserved `builtin:` namespace so they can never
/// collide with a document's own imported assets. A shader references one as
/// the `file` of an image-init texture, e.g.:
///
///     init = { kind = "image", file = "builtin:mandrill" }
///
/// or as a sampled input. The runtime resolves the name through
/// ``PhosphorRuntime`` after first checking document assets, so a document
/// asset of the same (non-prefixed) name still wins for plain names; the
/// `builtin:` prefix forces the framework copy.
public enum BuiltinTextures {
    /// The reserved namespace prefix for built-in texture names.
    public static let namespace = "builtin:"

    /// One shipped texture: a stable id and the resource file backing it.
    public struct Entry: Hashable, Sendable {
        /// Fully-qualified name including the `builtin:` prefix.
        public let name: String
        /// Short human label for pickers (no prefix).
        public let displayName: String
        /// Resource filename inside `Resources/BuiltinTextures`.
        public let resource: String

        /// Bare id without the `builtin:` prefix (e.g. `"mandrill"`).
        public var id: String { String(name.dropFirst(BuiltinTextures.namespace.count)) }
    }

    /// All shipped textures, in display order.
    public static let all: [Entry] = [
        Entry(name: "builtin:mandrill", displayName: "Mandrill", resource: "mandrill.png"),
        Entry(name: "builtin:testcard", displayName: "Test Card", resource: "testcard.jpg"),
        Entry(name: "builtin:noise-white", displayName: "White Noise", resource: "noise-white.png"),
        Entry(name: "builtin:noise-white-rgb", displayName: "White Noise (RGB)", resource: "noise-white-rgb.png"),
        Entry(name: "builtin:noise-value", displayName: "Value Noise", resource: "noise-value.png"),
        Entry(name: "builtin:noise-fbm", displayName: "Fractal Noise (fBm)", resource: "noise-fbm.png"),
        Entry(name: "builtin:noise-blue", displayName: "Blue Noise", resource: "noise-blue.png")
    ]

    /// True when `name` is in the reserved built-in namespace.
    public static func isBuiltin(_ name: String) -> Bool {
        name.hasPrefix(namespace)
    }

    /// Looks up an entry by fully-qualified name (with or without the prefix).
    public static func entry(named name: String) -> Entry? {
        let qualified = isBuiltin(name) ? name : namespace + name
        return all.first { $0.name == qualified }
    }

    /// Loads a built-in texture as a ``PhosphorAsset``, decoding lazily from
    /// the framework bundle. Returns `nil` if the name isn't a known built-in
    /// or the resource is missing. Results are cached for the process.
    public static func asset(named name: String) -> PhosphorAsset? {
        guard let entry = entry(named: name) else { return nil }
        return cache.withLock { cache in
            if let cached = cache[entry.name] { return cached }
            guard let data = loadData(for: entry) else { return nil }
            let asset = PhosphorAsset(name: entry.name, data: data)
            cache[entry.name] = asset
            return asset
        }
    }

    private static let cache = OSAllocatedUnfairLock<[String: PhosphorAsset]>(initialState: [:])

    private static func loadData(for entry: Entry) -> Data? {
        let resourceName = (entry.resource as NSString).deletingPathExtension
        let ext = (entry.resource as NSString).pathExtension
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: ext,
            subdirectory: "BuiltinTextures"
        ) ?? Bundle.module.url(forResource: resourceName, withExtension: ext) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
