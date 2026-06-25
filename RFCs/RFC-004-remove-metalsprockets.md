# RFC-004: Remove MetalSprockets Dependency from PhosphorKit

Status: Draft
Tracking issue: [#121](../ISSUES.md)
Date: 2026-06-25

## Summary

Make PhosphorKit's `PhosphorRuntime` stand on its own with raw Metal, dropping
its dependency on MetalSprockets / MetalSprocketsAddOns / MetalSprocketsUI /
MetalSprocketsSupport. The render is currently expressed in the MetalSprockets
(MS) declarative DSL — `Element`, `Group`, `ForEach`, `ComputePass`,
`ComputePipeline`, `ComputeKernel`, `ComputeDispatch`, `RenderPass`,
`TextureBillboardPipeline`, `@MSEnvironment(\.device)`, and the SwiftUI
`RenderView`/`RenderViewContext` host. We replace each of these with explicit
Metal: a per-frame command buffer, hand-rolled compute encoders, a cached
pipeline-state store, an argument-buffer residency pass, and a final
texture-to-drawable blit, hosted in a plain `MTKView`.

The implementation lives entirely in **PhosphorKit** (`Sources/PhosphorRuntime`);
this RFC tracks against #121 in the Phosphor repo for visibility because the app
links PhosphorRuntime.

## Motivation

See [#121](../ISSUES.md). PhosphorKit is meant to be the dependency-free source
of truth for parse / compile / render. MetalSprockets is the only heavyweight
external dependency left in the render path, and the runtime uses a thin,
well-understood slice of it (compute dispatch + a billboard blit). Owning that
slice in raw Metal removes the dependency, removes a layer of indirection over
the frame loop, and makes the render path easier to debug with the GPU tools.

## Non-goals

- Changing the shader/front-matter model, the compile pipeline, or any public
  PhosphorModel / PhosphorCompile API. Pure render-layer swap.
- Changing observable rendering behavior. Ping-pong parity, audio-buffer
  residency, and `flipY` handling must be byte-for-byte equivalent.
- Replacing `MTKView` with a custom `CAMetalLayer` view (possible later; out of
  scope here).
- Fixing the pre-existing Voxels example failure.

## Where MetalSprockets is used today

All in `PhosphorRuntime`:

- `PhosphorPipeline.swift` — the whole render, built on the MS DSL: `Element`,
  `Group`, `ForEach`, `ComputePass`, `ComputePipeline`, `ComputeKernel`,
  `ComputeDispatch`, `RenderPass`, `TextureBillboardPipeline`,
  `@MSEnvironment(\.device)`, `.parameter(...)`, `.onWorkloadEnter { ... }`.
- `PhosphorView.swift` — `RenderView` / `RenderViewContext` (MetalSprocketsUI)
  for the SwiftUI-hosted `MTKView`.
- `PlaybackClock.swift` — MS usage.
- `PhosphorCompiler.swift` — comment reference only (pipeline-state caching note).
- `Package.swift` — `dependencies`: MetalSprockets, MetalSprocketsAddOns;
  `products` re-exported: MetalSprockets, MetalSprocketsUI,
  MetalSprocketsSupport, MetalSprocketsAddOns.
- `Tests/PhosphorRuntimeTests/RenderSmokeTests.swift`, `README.md`.

## Design

### Frame loop (replaces `PhosphorPipeline.body`)

A single `render(drawable:drawableSize:)` entry point, called once per frame
from the view's draw callback, does what `PhosphorPipeline.body` does today:

1. `runtime.ensureTextures(drawableSize:)`, `writeAudioBuffers()`,
   `writeUserUniforms(...)` — unchanged; these are already raw-Metal helpers on
   `PhosphorRuntime`.
2. Compute the per-resource parity map from the frame counter (even → A,
   odd → B; non-ping-pong → always A) — unchanged logic, lifted verbatim out of
   `body`.
3. `writePassUniforms(builtin:parity:)` → per-pass `useResource` lists —
   unchanged.
4. Acquire one `MTLCommandBuffer`. For each enabled pass, encode a compute pass
   (below). Then encode the billboard blit (below). Commit, present the
   drawable.

No state beyond what `PhosphorRuntime` already holds; parity stays
frame-counter-derived.

### Compute pass (replaces `ComputePass` / `ComputePipeline` / `ComputeDispatch`)

Per enabled pass with a resolved function, write target, and uniforms buffer:

- Look up (or create + cache) the `MTLComputePipelineState` for the pass's
  `MTLFunction` (see pipeline cache below).
- `computeCommandEncoder` on the command buffer; set the pipeline state.
- Bind buffers at the indices the generated kernels expect:
  `uniforms` (per-pass buffer), `userUniforms` (shared buffer). The current
  `.parameter("uniforms", buffer:offset:)` calls already pin these by name via
  MS reflection; we replace them with explicit `setBuffer(_:offset:index:)`
  using the kernel's argument indices. Confirm the indices against the
  generated kernel signature in PhosphorCompile (Phosphor.h).
- Residency: replicate `onWorkloadEnter` — `encoder.useResource(tex, usage:
  [.read, .write])` for each texture in the pass's `useResources` list, plus
  `useResource(runtime.waveformBuffer, usage: .read)` and
  `useResource(runtime.spectrumBuffer, usage: .read)` (the `Uniforms` argument
  buffer references the audio buffers by `gpuAddress`).
- Dispatch: `threadsPerGrid = (writeTarget.width, writeTarget.height, 1)`,
  `threadsPerThreadgroup = (16, 16, 1)` — identical to today's
  `ComputeDispatch`. Use `dispatchThreads(_:threadsPerThreadgroup:)`
  (non-uniform threadgroups) to match MS's behavior. End encoding.

`primaryWriteTexture(for:parity:)` (first `.write`/`.readWrite` binding drives
the grid size) carries over unchanged.

### Pipeline-state cache (currently owned by MetalSprockets)

Add an `MTLComputePipelineState` cache keyed by pass id (or function), built
lazily on first use and invalidated when the runtime reloads. PhosphorCompiler
already has a note pointing at this. The cache is the only genuinely new piece
of ownership; everything else is a 1:1 lowering of existing DSL calls.

### Billboard blit (replaces `TextureBillboardPipeline`)

Final step: sample the output texture's current write target (chosen via
`displayedResource` ?? `configuration.output`, same parity as the writing pass)
and draw it full-screen to the drawable.

- A tiny built-in vertex+fragment shader pair shipped in PhosphorRuntime that
  draws a full-screen triangle/quad and samples one texture.
- `flipY` handling: when set, use flipped texture coordinates
  (`min: [0,1], max: [1,0]`) exactly as `TextureBillboardPipeline` does today
  via the `Quad`.
- A `RenderPassDescriptor` targeting the drawable's texture, one
  render-command encoder, draw, end.

### SwiftUI host (replaces `RenderView` / `RenderViewContext`)

`PhosphorView` becomes an `NSViewRepresentable`/`UIViewRepresentable` wrapping a
plain `MTKView`:

- Owns the `MTLDevice`, sets it on the view, owns an `MTKViewDelegate`.
- `mtkView(_:drawableSizeWillChange:)` forwards the new size.
- `draw(in:)` calls `runtime.render(drawable:view.currentDrawable,
  drawableSize:view.drawableSize)` inside the autorelease pool.
- Drives redraw via the existing `PlaybackClock` (replace its MS usage with a
  `CADisplayLink` / `CVDisplayLink` or `MTKView.isPaused`/`preferredFPS`).

## Package changes

- Remove `MetalSprockets` and `MetalSprocketsAddOns` from `Package.swift`
  `dependencies`.
- Remove the re-exported MS products. Audit downstream
  (`Packages/PhosphorSupport`, the app) for any `import MetalSprockets*` —
  none expected outside PhosphorRuntime, but verify.

## Testing

- `RenderSmokeTests.swift` rewritten to drive `runtime.render(...)` against an
  offscreen drawable/texture instead of the MS smoke harness.
- Visual parity check: a GPU capture of a known shader (e.g. HelloWorld) on the
  MS build vs. the raw-Metal build, comparing the final drawable and an
  intermediate ping-pong texture for byte equivalence (ping-pong parity, audio
  buffers, flipY).
- Existing PhosphorRuntime tests pass, excluding the known Voxels failure.

## Acceptance

- `Package.swift` has no MetalSprockets dependencies or products.
- No `import MetalSprockets*` anywhere in PhosphorKit or downstream.
- PhosphorRuntime renders identically (ping-pong parity, audio buffers, flipY).
- Tests pass (excluding the pre-existing Voxels failure).

## Risks / open questions

- **Argument-buffer / kernel binding indices.** MS bound `uniforms` /
  `userUniforms` by name via reflection; we must pin the exact buffer indices
  the generated kernels expect. Wrong indices = silent garbage. Confirm against
  Phosphor.h / the generated signatures and assert in debug.
- **Threadgroup uniformity.** Match MS's dispatch (non-uniform threadgroups via
  `dispatchThreads`) so edge tiles aren't dropped or doubled.
- **Effort: XL.** Largest single piece is the frame loop + residency + billboard
  port; the pipeline cache and view host are smaller but new.
