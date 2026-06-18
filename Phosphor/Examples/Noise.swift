import Foundation
import PhosphorSupport

/// Salt-and-pepper noise: every pixel hashes (gid, frame) to a random value.
/// No ping-pong, no channels. If this shows static noise that animates, the
/// uniforms + per-pixel-write path is fully working.
enum Noise {
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

    static inline uint wangHash(uint x) {
        x = (x ^ 61u) ^ (x >> 16);
        x *= 9u;
        x ^= x >> 4;
        x *= 0x27d4eb2du;
        x ^= x >> 15;
        return x;
    }

    kernel void image(
        texture2d<float, access::write> outTexture     [[texture(0)]],
        device const ChannelBindings&   channels       [[buffer(1)]],
        constant Uniforms&              uniforms       [[buffer(0)]],
        device const UserUniforms*      userUniforms   [[buffer(2)]],
        uint2 gid                                      [[thread_position_in_grid]])
    {
        uint frameSeed = uint(uniforms.frame);
        uint seed = wangHash(gid.x * 1973u + gid.y * 9277u + frameSeed * 26699u);
        float r = float(seed & 0xffu) / 255.0;
        float v = r < 0.35 ? 1.0 : 0.0;
        outTexture.write(float4(v, v, v, 1.0), gid);
    }
    """
}
