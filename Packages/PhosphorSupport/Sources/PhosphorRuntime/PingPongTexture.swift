import Foundation
import PhosphorModel
import Metal

/// A pair of textures (or just one, if `pingPong == false`) that the runtime
/// uses to manage feedback for a single ``Resource``.
public struct PingPongTexture {
    public let pingPong: Bool
    public var a: MTLTexture
    public var b: MTLTexture

    /// Returns the write target for the given parity.
    public func writeTexture(currentIsA: Bool) -> MTLTexture { currentIsA ? a : b }

    /// Returns the read source for the given parity.
    public func readTexture(currentIsA: Bool) -> MTLTexture {
        pingPong ? (currentIsA ? b : a) : a
    }
}
