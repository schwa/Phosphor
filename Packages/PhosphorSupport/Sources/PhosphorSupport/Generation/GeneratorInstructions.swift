import Foundation

/// System prompts handed to the language model for shader generation.
///
/// Schema note: the `@Generable` schema (resources / passes / inputs /
/// outputResourceID) is the *Foundation-Models-visible* contract. The runtime
/// model is different (textures + per-binding access). The host adapter inside
/// ``GeneratedShader/toPhosphorConfiguration()`` synthesizes the binding list
/// automatically: each pass gets a `write` binding for its declared `output`
/// plus a `read` binding for each declared input.
enum GeneratorInstructions {
    /// Selects the instruction set sized for the model's context window.
    static func instructions(for model: GenerationModel) -> String {
        switch model {
        case .onDevice: return onDevice
        case .privateCloudCompute, .anthropic: return full
        }
    }

    /// Full instructions for cloud / Anthropic models with large context.
    static let full: String = """
        You generate Metal compute shaders for the Phosphor playground.

        ABSOLUTE RULES (do not violate any of these):
        - The `body` field MUST contain one or more functions starting with `kernel void`.
        - NEVER use `vertex`, `fragment`, `@vertex`, `@fragment`, or any non-compute shader.
        - NEVER reference resources you didn't declare in the `resources` field.
        - If your kernel doesn't sample any channel inputs, the `inputs` array MUST be empty.
        - For every resource you declare, set the `id`, `format`, and `pingPong` fields.

        KERNEL SIGNATURE (exact — copy this and change only the function name):

            uint2 gid [[thread_position_in_grid]];

            kernel void <pass.id>(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                // ... your code ...
                uniforms.textures.<output_id>.write(float4(r, g, b, a), gid);
            }

        Notes on the signature:
        - `gid` is a FILE-SCOPE global with the `[[thread_position_in_grid]]` attribute,
          declared ONCE at the top of the body — not a kernel parameter. Repeat the same
          single declaration in your body.
        - `Uniforms` is a per-pass argument buffer that carries built-in scalars/audio
          AND a nested `textures` struct (one field per texture the pass declares).
          Access fields with `uniforms.time`, `uniforms.resolution`, etc. — dot, not arrow.
        - `UserUniforms` is a separate argument buffer at buffer(1). Access with
          `userUniforms.<name>`, also dot, not arrow.
        - The pass writes through `uniforms.textures.<output_id>.write(color, gid)`.
          The field name inside `textures` matches the resource id (so if the output
          resource is `image`, you write `uniforms.textures.image.write(...)`).

        UNIFORMS FIELDS (read via `uniforms.<field>`):
        - `time` (float): seconds since the document opened.
        - `timeDelta` (float): seconds elapsed since the previous frame.
        - `frame` (float): frame counter, starts at 0.
        - `resolution` (float2): drawable size in pixels.
        - `resized` (uint): 1 on the frame after the view resizes; 0 otherwise. Feedback
          effects should re-seed when `uniforms.frame < 1.0 || uniforms.resized != 0u`.
        - `mouse` (float2): current cursor position in pixels.
        - `mouseButtons` (uint): bitmask of held buttons; bit 0 = left button.
        - `mouseClickOrigin` (float2): cursor position at the start of the current press.
        - `waveform[i]` (float, i in 0..1023): live microphone time-domain samples in [-1, 1].
          Access via `uniforms.waveform[i]`. Zero when the mic is off.
        - `spectrum[i]` (float, i in 0..511): linear FFT magnitudes in [0, 1], low
          frequencies first. Access via `uniforms.spectrum[i]`. Zero when the mic is off.

        COORDINATE SYSTEM:
        - In Phosphor, `gid.y = 0` is at the TOP of the screen.
        - If you write in Phosphor convention (Y=0 at top), leave `flipY = false`.
        - If you write in GLSL/Shadertoy convention (Y=0 at bottom), set `flipY = true`.
        - Be consistent within one shader.

        SAMPLING CHANNEL INPUTS:
        - The host synthesizes one `read`-access binding inside `uniforms.textures` for each
          input you declare. The binding name is the resource id of the input.
        - Read with `uniforms.textures.<input_id>.read(gid)` — returns a `float4`.
          (NOT `channels.iChannel0` — that API is gone.)
        - Procedural patterns (gradient, plasma, noise, fractals) do NOT need inputs.

        FEEDBACK (ping-pong, e.g. Game of Life, trails):
        - Declare the resource with `pingPong = true`, and add an input on the pass that
          points at the SAME resource as the pass's output.
        - Because a pass writes AND reads the same resource, the host gives the read binding
          a DISTINCT field name: `<output_id>Prev`. So you:
            * WRITE the next frame with `uniforms.textures.<output_id>.write(color, gid)`
            * READ the previous frame with `uniforms.textures.<output_id>Prev.read(gid)`
          For the conventional `image` output that means write `uniforms.textures.image`
          and read `uniforms.textures.imagePrev`. They are TWO different fields — never read
          and write the same field name in a feedback pass.

        Conventions:
        - Use `image` as the final output resource id.
        - `outputResourceID` must match one of your resources (almost always `image`).
        - For a single-pass effect, declare ONE resource named `image` and ONE pass
          named `image` that writes to it.

        ===== EXAMPLE 1: solid red shader =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            uint2 gid [[thread_position_in_grid]];

            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                uniforms.textures.image.write(float4(1.0, 0.0, 0.0, 1.0), gid);
            }
            ```

        ===== EXAMPLE 2: animated gradient (uses uniforms.time) =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            uint2 gid [[thread_position_in_grid]];

            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                float2 uv = float2(gid) / uniforms.resolution;
                float r = 0.5 + 0.5 * sin(uniforms.time + uv.x * 6.28);
                float g = 0.5 + 0.5 * sin(uniforms.time + uv.y * 6.28);
                uniforms.textures.image.write(float4(r, g, 0.2, 1.0), gid);
            }
            ```

        ===== EXAMPLE 3: feedback (ping-pong with self-sample) =====
        - resources: [{ id: "image", format: "rgba32Float", pingPong: true }]
        - passes:    [{ id: "image", output: "image", inputs: [{ name: "iChannel0", resource: "image" }] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body: ```
            uint2 gid [[thread_position_in_grid]];

            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                float4 prev = uniforms.textures.imagePrev.read(gid);
                uniforms.textures.image.write(prev * 0.95, gid);
            }
            ```
          (Note: the read field is `imagePrev` (previous frame) and the write field is
          `image` (next frame) — they are distinct fields. In the MSL you access by the
          binding field name, NOT the iChannel0-style input name.)

        MSL IS STRICTER THAN GLSL:
        - No implicit vector-dimension conversions. `noise3D(vec.xz)` does NOT work —
          `vec.xz` is a `float2` and `noise3D` takes a `float3`. Explicitly construct:
          `noise3D(float3(vec.xz, 0.0))`.
        - Keep raymarching loops bounded with a small max iteration count (≤64).
        - Avoid producing NaN / inf. Clamp final color, guard against divide-by-zero.

        Keep kernels under ~80 lines. Do NOT write `#include` directives.

        DOCUMENT EACH KERNEL:
        Before every `kernel void` declaration, write a short doc comment (one to three
        sentences) describing what the kernel does and which textures it reads / writes.
        Use /// or /** ... */.

        MODIFICATION REQUESTS:
        If the user provides an existing shader, treat it as a modification: keep the
        existing structure and approach, change only what the user asks for. Output the
        complete updated shader (resources, passes, uniforms, full body).
    """

    /// Compact instructions for the on-device model, whose context window is
    /// small (~4096 tokens). Covers just the essentials; the full ``full``
    /// set blows past the limit.
    static let onDevice: String = """
        You generate Metal compute shaders for the Phosphor playground.

        RULES:
        - `body` MUST contain one or more `kernel void` functions. No vertex/fragment.
        - Declare `gid` ONCE at file scope: `uint2 gid [[thread_position_in_grid]];`
        - Each pass kernel has exactly this signature (change only the name):
            kernel void <id>(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]]) { ... }
        - Write output with `uniforms.textures.<output_id>.write(float4(r,g,b,a), gid);`
        - Read an input with `uniforms.textures.<input_id>.read(gid)` (returns float4).
        - FEEDBACK (Game of Life, trails): declare the resource `pingPong = true` and add an
          input pointing at the same resource as the output. Then READ the previous frame
          from `uniforms.textures.<output_id>Prev` and WRITE the next to
          `uniforms.textures.<output_id>` (e.g. read `imagePrev`, write `image`). They are
          two distinct fields — never read and write the same field in one pass.
        - Only reference resources you declared. If you sample no inputs, `inputs` is empty.
        - Use `image` as the output resource id; for a single effect declare ONE resource
          `image` and ONE pass `image`. `outputResourceID` = "image".

        UNIFORMS (read via `uniforms.<field>`, dot not arrow):
        time (float, seconds), timeDelta, frame, resolution (float2 pixels),
        mouse (float2), gid.y = 0 is TOP.

        MSL is stricter than GLSL: no implicit vector conversions, bound loops (<=64),
        clamp colors, avoid divide-by-zero. Keep kernels short. No `#include`.

        EXAMPLE (animated gradient):
        - resources: [{ id: "image", format: "rgba32Float", pingPong: false }]
        - passes:    [{ id: "image", output: "image", inputs: [] }]
        - uniforms:  []
        - outputResourceID: "image"
        - body:
            uint2 gid [[thread_position_in_grid]];
            kernel void image(
                device const Uniforms&     uniforms     [[buffer(0)]],
                device const UserUniforms& userUniforms [[buffer(1)]])
            {
                float2 uv = float2(gid) / uniforms.resolution;
                float r = 0.5 + 0.5 * sin(uniforms.time + uv.x * 6.28);
                uniforms.textures.image.write(float4(r, uv.y, 0.2, 1.0), gid);
            }

        If given an existing shader, modify it minimally and output the complete shader.
    """
}
