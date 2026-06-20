import Foundation
import Metal
import Observation
import os

/// Owns the lifecycle of a ``PhosphorRuntime`` for one editor session.
///
/// Both document types instantiate one of these as `@State`, call
/// ``reload(parsed:assets:audioCapture:)`` whenever the parsed source or
/// asset set changes, and inject `store.runtime` into the environment for
/// the rest of the view tree.
@Observable
@MainActor
public final class PhosphorRuntimeStore {
    /// The active runtime, or `nil` while the first reload is pending or
    /// after a failure.
    public private(set) var runtime: PhosphorRuntime?

    /// The most recent reload failure, if any. Cleared on the next
    /// successful reload.
    public private(set) var initError: Error?

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "runtime-store")

    public init() {}

    /// Reload the runtime in place. On the first call, builds a fresh
    /// runtime. On subsequent calls, mutates the existing one if possible.
    /// If `parsed.environment` is nil, drops the runtime.
    public func reload(
        parsed: ParsedPhosphorSource,
        assets: [String: PhosphorAsset],
        audioCapture: AudioCaptureEngine?
    ) {
        guard let environment = parsed.environment else {
            runtime = nil
            return
        }
        do {
            if let runtime {
                try runtime.update(
                    environment: environment,
                    source: parsed.body,
                    assets: assets
                )
            } else {
                guard let device = MTLCreateSystemDefaultDevice() else {
                    initError = PhosphorRuntimeStoreError.noMetalDevice
                    return
                }
                let newRuntime = try PhosphorRuntime(
                    device: device,
                    environment: environment,
                    source: parsed.body,
                    assets: assets
                )
                newRuntime.audioCapture = audioCapture
                runtime = newRuntime
            }
            initError = nil
        } catch {
            Self.logger.error("runtime reload failed: \(error, privacy: .public)")
            initError = error
        }
    }
}

public enum PhosphorRuntimeStoreError: Error, CustomStringConvertible {
    case noMetalDevice

    public var description: String {
        switch self {
        case .noMetalDevice: return "No Metal device available"
        }
    }
}
