import Foundation
import PhosphorSupport

/// Two-pass test: pass `source` writes solid blue, pass `image` samples
/// `source` via `iChannel0` and copies it to its own output. If the screen
/// shows blue, channel sampling works.
///
/// No ping-pong: both resources are simple write-then-read in one frame.
enum ChannelTest {
    static let environment = PhosphorEnvironment(
        resources: [
            .texture2D(id: "source", spec: .init(
                size: .drawable,
                format: .rgba32Float,
                pingPong: false,
                flipTiming: .endOfFrame,
                initial: .zero
            )),
            .texture2D(id: "image", spec: .init(
                size: .drawable,
                format: .rgba32Float,
                pingPong: false,
                flipTiming: .endOfFrame,
                initial: .zero
            )),
        ],
        passes: [
            Pass(
                id: "source",
                inputs: [],
                output: "source"
            ),
            Pass(
                id: "image",
                inputs: [.init(name: "iChannel0", resource: "source")],
                output: "image"
            ),
        ],
        output: "image"
    )

    static let source: String = """
    #include "Phosphor.h"

    kernel void source(
        texture2d<float, access::write> outTexture     [[texture(0)]],
        device const ChannelBindings&   channels       [[buffer(1)]],
        constant Uniforms&              uniforms       [[buffer(0)]],
        device const UserUniforms*      userUniforms   [[buffer(2)]],
        uint2 gid                                      [[thread_position_in_grid]])
    {
        outTexture.write(float4(0.0, 0.0, 1.0, 1.0), gid);
    }

    kernel void image(
        texture2d<float, access::write> outTexture     [[texture(0)]],
        device const ChannelBindings&   channels       [[buffer(1)]],
        constant Uniforms&              uniforms       [[buffer(0)]],
        device const UserUniforms*      userUniforms   [[buffer(2)]],
        uint2 gid                                      [[thread_position_in_grid]])
    {
        float4 sampled = channels.iChannel0.read(gid);
        outTexture.write(sampled, gid);
    }
    """
}
