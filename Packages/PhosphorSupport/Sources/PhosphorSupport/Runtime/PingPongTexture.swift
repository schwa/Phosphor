import Foundation
import Metal

/// A pair of textures (or just one, if `pingPong == false`) that the runtime
/// uses to manage feedback for a single ``Resource``.
public struct PingPongTexture {
    public let pingPong: Bool
    public var a: MTLTexture
    public var b: MTLTexture
    public var currentIsA: Bool = true

    public var writeTexture: MTLTexture { currentIsA ? a : b }
    public var readTexture: MTLTexture { pingPong ? (currentIsA ? b : a) : a }

    public mutating func flip() {
        if pingPong { currentIsA.toggle() }
    }
}
