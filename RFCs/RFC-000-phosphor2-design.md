# RFC-000: Phosphor 2 — Data-Driven Shadertoy for MetalSprockets

Status: Foundational (the original design doc; superseded in parts by later RFCs)
Date: 2026-06-18

> This is the founding design document for Phosphor 2, preserved as RFC-000.
> Later RFCs revise specific areas (see RFC-001 for the texture-model redesign).
> Where this doc and a later RFC disagree, the later RFC wins.

A standalone, new project. Not a fork of Phosphor 1. Phosphor 1 keeps existing
untouched; Phosphor 2 has its own package, target names, and demo (locations
TBD).

A multi-pass, resource-aware, data-driven Metal shader playground. The
"environment" is a value-type document held in memory. A single `.metal` file
can self-describe its environment via a TOML front-matter block; each pass is
a plain Metal `kernel void` named in the document.

## 1. Mental model

A Phosphor 2 effect is three things:

1. **Resources** — named textures. Each has a size, format, optional
   ping-pong behavior, optional `flipTiming`, and an initial-contents
   specification.
2. **Passes** — an ordered list of compute passes. Each pass reads any number
   of channel inputs by name, writes exactly one resource, and runs one
   Metal `kernel void` whose name matches the pass id.
3. **Output** — the resource ID that gets blitted to the drawable each frame.
   The host UI may override this at runtime for debugging, but the document
   has exactly one canonical output.

```
        ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
inputs─►│ Pass: bufA  │───►│ Pass: bufB  │───►│ Pass: image │──► drawable
        └──────┬──────┘    └──────┬──────┘    └─────────────┘
               │                  │                  ▲
               ▼                  ▼                  │
        ┌─────────────┐    ┌─────────────┐           │
        │ res: bufA   │◄───┤ res: bufB   │───────────┘  (sampled as iChannel0)
        │ (pingpong)  │    │ (pingpong)  │
        └─────────────┘    └─────────────┘
```

---

## 2. The environment document

A `PhosphorEnvironment` is a plain `Codable` value type. **Dumb on
construction**; `validate()` is a free function called at runtime.

```swift
public struct PhosphorEnvironment: Codable, Hashable, Sendable {
    public var resources: [Resource]
    public var passes:    [Pass]
    public var output:    ResourceID
    public var uniforms:  [UniformDecl] = []
}
```

### 2.1 Resource identity

```swift
public struct ResourceID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let raw: String
    public init(stringLiteral value: String) { self.raw = value }
}
```

### 2.2 Resources

```swift
public enum Resource: Codable, Hashable, Sendable {
    case texture2D(id: ResourceID, spec: Texture2DSpec)
}

public struct Texture2DSpec: Codable, Hashable, Sendable {
    public var size: TextureSize
    public var format: PhosphorPixelFormat
    public var pingPong: Bool
    public var flipTiming: FlipTiming = .endOfFrame
    public var initial: TextureInit
}

public enum TextureSize: Codable, Hashable, Sendable {
    case drawable
    case fixed(width: Int, height: Int)
    case scaledDrawable(Float)
}

public enum PhosphorPixelFormat: String, Codable, Hashable, Sendable {
    case rgba8Unorm, rgba16Float, rgba32Float
}

public enum FlipTiming: String, Codable, Hashable, Sendable {
    case endOfFrame   // Shadertoy semantics; later passes in same frame see last frame's contents
    case immediate    // flip after the writing pass; later passes see this frame's contents
}

public enum TextureInit: Codable, Hashable, Sendable {
    case zero
    case color(SIMD4<Float>)
    case image(name: String)       // resolved through host-injected asset registry
    case noise(seed: UInt64)
}
```

Notes:

- **Default format: `rgba32Float`.** Per-resource override available.
- `pingPong: true` makes a resource behave like a Shadertoy Buffer: passes
  writing to it sample the *other* texture in the pair.
- `flipTiming` controls when the ping-pong swap happens:
  - `.endOfFrame` (default, Shadertoy semantics): later passes in the same
    frame see *last* frame's contents.
  - `.immediate`: flip happens right after the writing pass; later passes see
    this frame's just-written contents. Requires inter-dispatch
    synchronization (split command buffer or fence). **Defer
    implementation to a later step.**
- **Resize behavior:** when the drawable size changes, `.drawable` and
  `.scaledDrawable(_)` resources are reallocated and zero-filled — feedback
  state is discarded. `.fixed(w,h)` is the escape hatch for resize-stable
  state. Matches Shadertoy.

### 2.3 Passes

```swift
public struct Pass: Codable, Hashable, Sendable {
    public var id: ResourceID        // also the kernel function name
    public var inputs: [Binding]     // [{ name: "iChannel0", resource: "bufA" }, ...]
    public var output: ResourceID    // bound as outTexture
    public var enabled: Bool = true
}

public struct Binding: Codable, Hashable, Sendable {
    public var name: String          // "iChannelN"; runtime validates against inferred channel count
    public var resource: ResourceID
}
```

**Channel count is inferred** from `max(iChannelN referenced) + 1` across all
passes. There is no fixed rack size. The runtime auto-generates a
`ChannelBindings` struct sized to the inferred count.

**Dispatch:** grid is always exactly the output texture size, threadgroup is
hardcoded `16×16×1`. Always 2D. Tuning hooks are not in 1.0.

**No `PassKind`.** Everything is compute. Render passes (vertex+fragment) are
explicitly out of scope.

### 2.4 User uniforms

```swift
public struct UniformDecl: Codable, Hashable, Sendable {
    public var name: String
    public var kind: UniformKind
    public var defaultValue: UniformValue
    public var ui: UniformUIHint?
}

public enum UniformKind: String, Codable, Hashable, Sendable {
    case float, float2, float3, float4, int, bool, color
}

public enum UniformValue: Codable, Hashable, Sendable {
    case float(Float), float2(SIMD2<Float>), float3(SIMD3<Float>), float4(SIMD4<Float>)
    case int(Int32), bool(Bool)
}

public enum UniformUIHint: Codable, Hashable, Sendable {
    case slider(min: Float, max: Float)
    case color
    case toggle
    case vector
}
```

- **One shared `UserUniforms` struct** across all passes.
- The runtime **auto-generates** the `struct UserUniforms { ... };` typedef
  from `env.uniforms` and **prepends it to each pass's source** before
  compilation.
- Host UI reads `env.uniforms` and renders controls per `UniformUIHint`
  (`Slider`, `ColorPicker`, `Toggle`, vector field). Live values flow into the
  user-uniforms buffer each frame.

### 2.5 Assets

```swift
public enum PhosphorAsset: Hashable, Sendable {
    case cgImage(CGImage)
}
```

The host (`PhosphorView`) takes an optional `assets: [String: PhosphorAsset]`
parameter. `TextureInit.image(name:)` resolves through that dict. Unknown
names produce a diagnostic and fall back to zero-init. Assets are
**not `Codable`** for now.

---

## 3. Kernels and bindings

### 3.1 The fixed kernel signature

Every pass is a plain `kernel void`. Signatures are **100% identical** across
all kernels — no macro, no flexibility, no reflection-driven binding. Authors
copy the signature verbatim:

```metal
#include "Phosphor.h"

kernel void bufA(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    // your code here
}
```

If the user gets the signature wrong, the Metal compiler error is the
diagnostic. The runtime does not try to validate or fix it.

### 3.2 `Uniforms` (built-in)

Declared in `Phosphor.h`. Field layout for the host-side mirror is whatever
makes alignment correct; the runtime owns padding details.

```c
struct Uniforms {
    float    time;            // seconds, host-controlled (pause/reset live in the demo view)
    float    timeDelta;       // seconds since previous frame
    float    frame;           // frame counter as float (matches Shadertoy iFrame)
    uint     channelCount;    // inferred channel count, exposed for shader use
    float2   resolution;      // drawable size in pixels
    float2   mouse;           // current xy in pixels
    uint     mouseButtons;    // bitmask: bit 0 = left, bit 1 = right, bit 2 = middle
    float2   mouseClickOrigin; // xy where current/last press began
};
```

`time` and `frame` are host-owned; pause/reset are demo-view concerns and not
modeled in the document.

### 3.3 `ChannelBindings` (auto-generated per environment)

Sized to the inferred channel count. Uses the `TEXTURE2D` macro from
`MetalSprocketsShaders.h` so the same struct is valid on Metal (textures) and
Swift (`MTLResourceID`):

```c
struct ChannelBindings {
    TEXTURE2D(float, access::read) iChannel0;
    TEXTURE2D(float, access::read) iChannel1;
    // ...up to inferred count
};
```

Bound as a **Metal 3 bindless argument buffer**: the runtime writes
`MTLResourceID`s into a regular `MTLBuffer` and binds it as
`.parameter("channels", buffer: ...)`. Resources referenced through it get
`useResource(_:usage:)` calls on the compute encoder each pass. The argument
buffer is rebuilt every frame — it's tiny (4 × `MTLResourceID` is 32 bytes).

For passes that don't bind a particular channel: that slot in the argument
buffer points at a cached zero texture. Sampling it returns zero. Avoids GPU
faults from unbound texture handles.

### 3.4 `UserUniforms` (auto-generated per environment)

Generated from `env.uniforms` and **prepended to each pass's source string
before compilation**. This is the one source-level transformation Phosphor 2
performs. It's narrow, mechanical, and testable in isolation.

```c
struct UserUniforms {
    float    intensity;
    float3   tint;
    bool     useFeedback;
    // ...
};
```

Host-side mirror is similarly generated; the runtime memcpys values from the
host UI state into the `MTLBuffer` once per frame.

### 3.5 Source layout

The whole `.metal` file is one compilation unit. Multiple `kernel void`
declarations live at file scope. Helpers are normal file-scope functions and
can be called by any kernel.

No section delimiters. No `// %%` markers. Pass id → kernel name; the runtime
looks up the function in the compiled library by name.

---

## 4. The self-describing snippet (TOML front-matter)

A `.metal` file can carry its environment in a TOML front-matter block at
the top of the file, fenced in a Metal comment.

```metal
/* phosphor:environment
output = "image"

[[resources]]
kind = "texture2D"
id = "bufA"
spec = { size = "drawable", format = "rgba16Float", pingPong = true, flipTiming = "endOfFrame", initial = "zero" }

[[resources]]
kind = "texture2D"
id = "image"
spec = { size = "drawable", format = "rgba16Float", pingPong = false, initial = "zero" }

[[passes]]
id = "bufA"
output = "bufA"
inputs = [
    { name = "iChannel0", resource = "bufA" },
]

[[passes]]
id = "image"
output = "image"
inputs = [
    { name = "iChannel0", resource = "bufA" },
]

[[uniforms]]
name = "intensity"
kind = "float"
default = 1.0
ui = { slider = { min = 0.0, max = 4.0 } }
*/

#include "Phosphor.h"

kernel void bufA(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    // feedback step
    float4 prev = channels.iChannel0.read(gid);
    float2 uv = float2(gid) / uniforms.resolution;
    outTexture.write(prev * 0.98 + 0.02 * float4(uv, 0, 1) * userUniforms->intensity, gid);
}

kernel void image(
    texture2d<float, access::write> outTexture     [[texture(0)]],
    device const ChannelBindings&   channels       [[buffer(1)]],
    constant Uniforms&              uniforms       [[buffer(0)]],
    device const UserUniforms*      userUniforms   [[buffer(2)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    outTexture.write(channels.iChannel0.read(gid), gid);
}
```

### 4.1 Parser

1. Find `/* phosphor:environment` and matching `*/`. Extract TOML body.
2. Parse TOML → `PhosphorEnvironment`.
3. Call `validate(env)` — see §5.
4. Channel count = `max(iChannelN referenced in any pass.inputs) + 1`.
5. Generate `ChannelBindings` and `UserUniforms` typedefs.
6. Prepend the generated typedefs to the (front-matter-stripped) source.
7. Compile the whole thing as one `MTLLibrary`.
8. For each pass, pull `library.makeFunction(name: pass.id.raw)` and build
   an `MTLComputePipelineState`.

If there's no front-matter, parsing fails. There is no implicit
single-pass default and no legacy `mainImage` fallback — Phosphor 2 is a
clean break.

---

## 5. Validation & diagnostics

```swift
public func validate(_ env: PhosphorEnvironment) -> [PhosphorDiagnostic]
```

Pure function over the document. Returns diagnostics; the runtime decides
whether any of them are fatal (validation errors are; per-pass compile
errors are not — see below).

```swift
public enum PhosphorDiagnostic: Hashable, Sendable {
    case frontMatterParse(String, line: Int?)
    case unknownResource(ResourceID, in: String)
    case duplicateResource(ResourceID)
    case duplicatePass(ResourceID)
    case unknownChannelName(String, in: ResourceID)
    case channelOutOfRange(name: String, inferred: Int)
    case missingOutput(ResourceID)
    case readWriteHazard(pass: ResourceID, resource: ResourceID)
    case compile(PhosphorCompileError)
}
```

**Per-pass compile failures are non-fatal.** Errored passes are skipped;
their output texture keeps its last contents (zero on first frame); downstream
passes continue with stale data. The user sees per-pass diagnostics in the
UI. This matches Shadertoy's behavior and is the most useful mode for live
editing.

**Front-matter parse errors and validation errors are fatal** — there's no
environment to render. The UI shows the error overlay.

---

## 6. The runtime

`PhosphorRuntime` owns the GPU-side state derived from a `PhosphorEnvironment`.

```swift
final class PhosphorRuntime {
    private(set) var textures: [ResourceID: PingPongTexture]
    private(set) var pipelines: [ResourceID: MTLComputePipelineState]   // keyed by pass.id
    private(set) var library: MTLLibrary?
    private(set) var channelBuffers: [ResourceID: MTLBuffer]            // per-pass arg buffer
    private(set) var uniformsBuffer: MTLBuffer
    private(set) var userUniformsBuffer: MTLBuffer
    private(set) var diagnostics: [PhosphorDiagnostic]

    func update(to env: PhosphorEnvironment, drawableSize: CGSize) async
}

struct PingPongTexture {
    let pingPong: Bool
    var a: MTLTexture
    var b: MTLTexture
    var currentIsA: Bool
    var writeTexture: MTLTexture { currentIsA ? a : b }
    var readTexture:  MTLTexture { currentIsA ? b : a }
    mutating func flip()  { if pingPong { currentIsA.toggle() } }
}
```

Per-frame work happens in the `Element` body via `onWorkloadEnter` and
`onCommandBufferCompleted` hooks. One-time work (texture allocation, library
compile, pipeline state creation) happens in `update(to:drawableSize:)`,
invoked off the render thread.

### 6.1 The pipeline element

```swift
struct PhosphorPipeline: Element {
    @MSEnvironment(\.device) var device
    @MSObservedObject var runtime: PhosphorRuntime

    let env: PhosphorEnvironment
    let builtinUniforms: PhosphorUniforms

    var body: some Element {
        get throws {
            try Group {
                try Group {
                    for pass in env.passes where pass.enabled {
                        try makeComputePass(pass)
                    }
                }
                if let outputTex = runtime.textures[env.output]?.readTexture {
                    try RenderPass {
                        try TextureBillboardPipeline(specifier: .texture2D(outputTex))
                    }
                }
            }
            .onWorkloadEnter { _ in
                runtime.writeBuiltinUniforms(builtinUniforms)
                runtime.writeUserUniforms(env.uniforms)
                runtime.rebuildChannelBuffers(for: env.passes)
            }
        }
    }

    @ElementBuilder
    private func makeComputePass(_ pass: Pass) throws -> some Element {
        guard let pipelineState = runtime.pipelines[pass.id],
              let outTex = runtime.textures[pass.output]?.writeTexture else {
            EmptyElement()
            return
        }

        try ComputePass(label: pass.id.raw) {
            try ComputePipeline(state: pipelineState) {
                try ComputeDispatch(
                    threadsPerGrid: MTLSize(width: outTex.width, height: outTex.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
                )
                .parameter("outTexture", texture: outTex)
                .parameter("channels", buffer: runtime.channelBuffers[pass.id]!)
                .parameter("uniforms", buffer: runtime.uniformsBuffer)
                .parameter("userUniforms", buffer: runtime.userUniformsBuffer)
            }
        }
        .onCommandBufferCompleted { _ in
            // endOfFrame flipping: deferred to the end of the whole frame, not here.
            // Handled by a single pass at the bottom of the element tree (see §6.2).
        }
    }
}
```

### 6.2 Flip timing

For `flipTiming: .endOfFrame` resources: one flip happens at the end of the
frame, after all passes have completed. Implementation: a final
`onCommandBufferCompleted` on the last pass (or on a synthetic element at
the bottom of the tree) walks all ping-pong resources marked `.endOfFrame`
and flips them once.

`.immediate` flipping is deferred to a later milestone.

---

## 7. Plan of attack

Each step ships something that compiles and renders.

1. **Define the data model.** `PhosphorEnvironment`, `Resource`,
   `Texture2DSpec`, `Pass`, `Binding`, `UniformDecl`, `ResourceID`. `Codable`
   + `Hashable`. Free function `validate(_:)`. Unit-test it.
2. **Phosphor.h header.** Declares `Uniforms` and the typedef macros. Lives
   in the shader target.
3. **Single-pass runtime.** Build `PhosphorRuntime` end-to-end for a
   hardcoded one-pass environment. One kernel, one ping-pong resource, no
   user uniforms, no channels yet. Get pixels on screen.
4. **Channel argument buffer + multi-pass.** Auto-generate `ChannelBindings`,
   plumb it through. Port a two-pass reaction-diffusion-style example to
   prove it.
5. **Static resource init (`TextureInit.image`).** Plumb the asset provider.
   Port an example that samples a noise texture.
6. **User-declared uniforms.** Auto-generate `UserUniforms` typedef, pack
   buffer, surface controls in the demo view per `UniformUIHint`.
7. **TOML front-matter parser.** Parse `/* phosphor:environment ... */`,
   decode to `PhosphorEnvironment`. Now a single `.metal` string fully
   describes its environment. Swift TOML parser TBD at implementation time
   (e.g. `TOMLKit`).
8. **`.immediate` flip timing.** Add the inter-dispatch synchronization path
   for resources that need it.
9. **(Stretch)** Editor UI for environment metadata: add/remove passes, tweak
   resource specs, rewire channels. Not required for 1.0.

---

## 8. Things explicitly out of scope

- Render passes (vertex+fragment). Compute-only.
- Cubemaps, video, audio, keyboard, webcam.
- Disk format, `.phosphor` bundles, file browser.
- DAG scheduling, conditional passes, per-pass frame rates.
- GPU-resident persistent buffers (atomics, etc.).
- Mesh shaders, tessellation.
- Pause/reset/time-scrubbing in the document (UI-only).
- The 19 Phosphor 1 examples. New examples, written from scratch in kernel
  form.
- `mainImage`-style snippets, `SnippetStyle`, `Support.h`, `[[stitchable]]`,
  `visible_function_table`, `MTLLinkedFunctions`. None of it survives.

---

## 9. Things explicitly resolved during design

For reference:

- **In-memory only.** No disk format, no asset directories, no file browser.
- **New project.** Not a fork. Phosphor 1 stays untouched.
- **Channels via Metal 3 bindless argument buffers.** `TEXTURE2D` macro,
  `MTLResourceID`s in an `MTLBuffer`, `useResource` on the encoder.
- **Channel count inferred** from `inputs[].name` usage. Exposed to shaders
  via `Uniforms.channelCount`.
- **Per-resource `flipTiming`** (`.endOfFrame` default; `.immediate` deferred
  to step 8).
- **Built-in `Uniforms`:** `time`, `timeDelta`, `frame`, `channelCount`,
  `resolution`, `mouse`, `mouseButtons`, `mouseClickOrigin`. Pause/reset is a
  host concern.
- **Default texture format: `rgba32Float`.**
- **Resize discards feedback state.** `.fixed(w,h)` is the escape hatch.
- **`UserUniforms` shared across all passes**, auto-generated, prepended to
  each pass's source.
- **`UserUniforms` only useful with live UI.** Hint-driven controls in the
  demo view.
- **Plain kernels**, no `[[stitchable]]`, no visible function tables.
- **Fixed kernel signature**, no macro. Authors write the canonical signature
  verbatim. Mismatches surface as Metal compile errors.
- **Assets host-injected** as `CGImage`s. Not `Codable`. Missing names →
  diagnostic + zero-init.
- **TOML front-matter**, fenced in `/* phosphor:environment ... */`.
  Hand-editable, comments supported, inline tables keep nesting flat.
- **No section delimiters in source files.** Pass id = kernel function name.
- **No `PassKind` enum.** Everything is compute.
- **No `dispatchScale`.** Grid = output texture size, threadgroup = 16×16.
- **`PhosphorEnvironment` is a dumb value.** `validate(_:)` is a free
  function called at runtime.
- **Per-pass compile errors are non-fatal.** Errored passes skipped, others
  continue. Diagnostics surface per-pass.
- **Single canonical output** in the document. UI debug-view-switching is
  layered on top.
- **The runtime is called `PhosphorRuntime`.** Not "materializer".
