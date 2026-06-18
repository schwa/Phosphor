import Foundation
import PhosphorSupport

/// Ping-pong feedback test: each frame samples its own previous output via
/// `iChannel0`, fades it to 95%, and writes a fresh white seed at the left
/// edge. Expected output: a faint white smear/trail. If the trail decays as
/// expected the ping-pong path works; if you only see a thin white column,
/// the kernel isn't sampling last frame's data.
enum Fade {
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
        float4 previous = channels.iChannel0.read(gid);
        float4 faded = previous * 0.97;
        // 80-pixel-wide white column scanning slowly (1 px/frame).
        float width = max(uniforms.resolution.x, 1.0);
        float columnX = fmod(uniforms.frame, width);
        float fx = float(gid.x);
        if (fx >= columnX && fx < columnX + 80.0) {
            faded = float4(1.0, 1.0, 1.0, 1.0);
        }
        outTexture.write(faded, gid);
    }
    """
}
