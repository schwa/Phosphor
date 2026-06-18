import Foundation
import PhosphorSupport

/// Ping-pong accumulator: each frame writes `previous + 0.01` (clamped).
///
/// Expected: screen fades from black to white over ~100 frames (~1.6s).
/// If ping-pong is broken, the screen stays a constant dim gray (~0.01).
enum Accumulate {
    static let environment = PhosphorEnvironment(
        resources: [
            .texture2D(id: "image", spec: .init(
                size: .drawable,
                format: .rgba32Float,
                pingPong: true,
                flipTiming: .endOfFrame,
                initial: .zero
            )),
        ],
        passes: [
            Pass(
                id: "image",
                inputs: [.init(name: "iChannel0", resource: "image")],
                output: "image"
            ),
        ],
        output: "image"
    )

    static let source: String = """
    #include "Phosphor.h"

    kernel void image(
        texture2d<float, access::write> outTexture     [[texture(0)]],
        device const ChannelBindings&   channels       [[buffer(1)]],
        constant Uniforms&              uniforms       [[buffer(0)]],
        device const UserUniforms*      userUniforms   [[buffer(2)]],
        uint2 gid                                      [[thread_position_in_grid]])
    {
        // Read the pixel one to the left from last frame.
        uint2 sampleCoord = uint2(gid.x > 0u ? gid.x - 1u : gid.x, gid.y);
        float4 shifted = channels.iChannel0.read(sampleCoord) * 0.99;
        // Seed a 20-pixel-tall white block at the top-left corner, every frame.
        float4 result = shifted;
        if (gid.x < 4u && gid.y < 20u) {
            result = float4(1, 1, 1, 1);
        }
        result.a = 1.0;
        outTexture.write(result, gid);
    }
    """
}
