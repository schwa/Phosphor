import Foundation
import PhosphorSupport

/// Trivial test kernel: writes a solid red color to every pixel. No ping-pong,
/// no channels sampled, no time dependence. If this doesn't show red on screen,
/// the bug is in the runtime/rendering path, not in the user kernel.
enum SolidColor {
    static let environment = PhosphorEnvironment(
        resources: [
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
                id: "image",
                inputs: [],
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
        outTexture.write(float4(0.25, 0.25, 0.25, 1.0), gid);
    }
    """
}
