# RFC-004: Make PhosphorKit MetalSprockets-Free; Move MetalSprockets Into the App

Status: Draft
Tracking issue: [#121](../ISSUES.md)
Date: 2026-06-25

## Summary

PhosphorKit becomes the standalone, dependency-light product that consumers
embed: **no MetalSprockets, ever.** It ships a raw-Metal render core plus an
`MTKView`-backed `PhosphorView`, so the entire integration contract for a
third-party app is:

1. Embed a `.phosphor` file as a resource.
2. Link PhosphorKit.
3. `PhosphorView(named: "Foo")`.

The MetalSprockets render layer that currently lives in PhosphorKit's
`PhosphorRuntime` (`PhosphorPipeline.swift`, the `RenderView`-based
`PhosphorView.swift`) is **deleted from PhosphorKit and re-created inside the
Phosphor app** (in `Packages/PhosphorSupport`). There it wraps PhosphorKit's
agnostic render core inside a MetalSprockets `RenderView` / `Element`, so the app
keeps everything MetalSprockets gives it (video import/export, the DSL, the
editor, generation glue).

Net result: **one renderer** — PhosphorKit's raw-Metal core — consumed two ways:
directly via PhosphorKit's `MTKView` host, or wrapped by the app's MetalSprockets
host. The only thing that exists twice is the thin view-host shell, and the
MetalSprockets shell is not in the library.

## Motivation

The core goal of Phosphor (see the Splash / About) is authoring `.phosphor`
animation files that drop into other people's Xcode projects via
`PhosphorView(named:)`. For that, PhosphorKit must be a clean, self-contained
dependency a consumer takes on purpose — not one that drags MetalSprockets and
its transitive graph into every embedding app's binary.

At the same time, MetalSprockets is genuinely valuable *inside Phosphor.app*
(video import/export, the declarative pipeline, the editor). So we don't remove
MetalSprockets from the product — we move it to where it belongs (the app) and
keep PhosphorKit agnostic.

This supersedes the earlier framing of this RFC ("remove MetalSprockets from
PhosphorKit's render path"). The render work is the same raw-Metal lowering; the
difference is that MetalSprockets is *relocated*, not eliminated, and PhosphorKit
keeps owning the single source-of-truth renderer.

## Non-goals

- Changing the shader / front-matter model, the compile pipeline, or any public
  PhosphorModel / PhosphorCompile API. Pure render-layer relocation + lowering.
- Changing observable rendering behavior. Ping-pong parity, audio-buffer
  residency, and `flipY` handling must stay byte-for-byte equivalent across both
  hosts.
- The SwiftUI `Shader`-effect zero-dep export — tracked separately in
  [#127](../ISSUES.md), explicitly out of scope here.
- A `PhosphorKitLite` split. Once PhosphorKit is MetalSprockets-free, it *is*
  the lean embeddable product; a further Lite split (dropping editor/codegen
  helpers) can be a follow-up if needed.
- Build-time shader precompilation (`.metallib` instead of runtime
  `makeLibrary(source:)`). Related and important, but its own piece of work.

## Architecture

```
PhosphorKit (no MetalSprockets):
  PhosphorModel          data model                         (already agnostic)
  PhosphorCompile        parse / compile / library          (already agnostic)
  PhosphorRuntime        raw-Metal render core + PhosphorView (this RFC)
     · pipeline-state cache
     · per-frame compute encoding (passes, dispatch, residency)
     · ping-pong parity, audio buffers, uniforms
     · texture -> drawable billboard blit
     · render(into:targetTexture:size:frame:...) entry point (view-agnostic)
     · PhosphorView: MTKView host that calls the core

Phosphor.app:
  Packages/PhosphorSupport
     · MetalSprockets RenderView / Element that wraps PhosphorKit's core
       (video import/export, DSL, editor) — the MetalSprockets code that used
       to live in PhosphorKit moves here.
```

### View-agnostic render entry point

The core exposes a single call that does **no** drawable/view acquisition of its
own, so either host can drive it:

```
func render(into commandBuffer: MTLCommandBuffer,
            targetTexture: MTLTexture,   // the drawable's texture, or any RT
            size: CGSize,
            frame: ...,                  // builtin uniforms / counters
            displayedResource: ResourceID?) throws
```

- PhosphorKit's `PhosphorView` (MTKView) acquires its own command buffer +
  `currentDrawable`, calls `render(into:...)`, presents, commits.
- The app's MetalSprockets `RenderView` hands the core a command buffer +
  target texture from inside the MS frame and lets MetalSprockets own
  presentation / compositing / video capture.

The current per-frame logic in `PhosphorPipeline.body` lowers 1:1 into this
function — the parity map, `ensureTextures`, `writeAudioBuffers`,
`writeUserUniforms`, `writePassUniforms`, per-pass dispatch with `useResource`
residency, and the final billboard — all of which already sit on
`PhosphorRuntime` as raw-Metal helpers.

### Compute pass (replaces `ComputePass` / `ComputePipeline` / `ComputeDispatch`)

Per enabled pass with a resolved function, write target, and uniforms buffer:

- Look up (or create + cache) the `MTLComputePipelineState` for the pass's
  function (pipeline cache below).
- `computeCommandEncoder`; set the pipeline state.
- Bind `uniforms` (per-pass buffer) and `userUniforms` (shared buffer) by their
  generated argument indices via `setBuffer(_:offset:index:)` (today MS binds
  these by name via reflection — confirm indices against Phosphor.h and assert
  in debug).
- Residency: `encoder.useResource(tex, usage: [.read, .write])` for each texture
  in the pass's `useResources` list, plus `useResource(waveformBuffer, .read)`
  and `useResource(spectrumBuffer, .read)` (the `Uniforms` argument buffer
  references the audio buffers by `gpuAddress`).
- Dispatch: `threadsPerGrid = (writeTarget.width, writeTarget.height, 1)`,
  `threadsPerThreadgroup = (16, 16, 1)`; use `dispatchThreads(_:...)`
  (non-uniform threadgroups) to match MS. End encoding.

`primaryWriteTexture(for:parity:)` carries over unchanged.

### Pipeline-state cache (currently owned by MetalSprockets)

Add an `MTLComputePipelineState` cache keyed by pass id / function, built lazily
and invalidated on reload. This is the one genuinely new piece of ownership;
everything else is a 1:1 lowering of existing DSL calls. PhosphorCompiler already
notes this.

### Billboard blit (replaces `TextureBillboardPipeline`)

A small built-in vertex+fragment pair shipped in PhosphorKit draws a full-screen
triangle and samples the chosen output texture (`displayedResource` ??
`configuration.output`, same parity as the writing pass). `flipY` uses flipped
texture coordinates (`min: [0,1], max: [1,0]`), exactly as today. One
`RenderPassDescriptor` targeting `targetTexture`, one encoder, draw, end.

### PhosphorView (PhosphorKit, replaces `RenderView` / `RenderViewContext`)

`NSViewRepresentable` / `UIViewRepresentable` wrapping a plain `MTKView`:
owns the device + `MTKViewDelegate`; `draw(in:)` calls `render(into:...)` with
the view's command buffer + `currentDrawable.texture`; redraw driven by the
existing `PlaybackClock` (re-homed off MetalSprockets onto
`CADisplayLink`/`CVDisplayLink` or `MTKView.preferredFramesPerSecond`).

### Phosphor.app MetalSprockets host (PhosphorSupport)

The deleted PhosphorKit MS code is re-created here as a `RenderView` / `Element`
that obtains a command buffer + target texture in the MS frame and calls
PhosphorKit's `render(into:...)`. This is where video import/export and the DSL
integration live.

## Package changes

- PhosphorKit `Package.swift`: remove MetalSprockets, MetalSprocketsAddOns
  dependencies and the re-exported MetalSprockets* products. No `import
  MetalSprockets*` anywhere in PhosphorKit.
- `Packages/PhosphorSupport`: add MetalSprockets dependency; host the new MS
  render view there.
- App: links PhosphorKit (renderer) + PhosphorSupport (MS host + generation).

## Testing

- `RenderSmokeTests` (PhosphorKit) rewritten to drive `render(into:...)` against
  an offscreen target texture instead of the MS harness.
- Visual parity: GPU capture of a known shader (e.g. HelloWorld) — compare the
  PhosphorKit `MTKView` path and the app's MetalSprockets path against the old
  MS-only output, byte-comparing the final drawable and an intermediate
  ping-pong texture (parity, audio buffers, flipY).
- PhosphorKit tests pass (excluding the known Voxels failure); the app builds and
  renders identically through the MS host.

## Acceptance

- PhosphorKit has no MetalSprockets dependency, product, or import.
- An app can embed a `.phosphor`, link only PhosphorKit, call
  `PhosphorView(named:)`, and render with no MetalSprockets in its binary.
- Inside Phosphor.app, the MetalSprockets `RenderView` (in PhosphorSupport) wraps
  PhosphorKit's core and renders identically, with video import/export intact.
- Tests pass (excluding the pre-existing Voxels failure).

## Risks / open questions

- **Kernel binding indices.** MS bound `uniforms` / `userUniforms` by name via
  reflection; the raw-Metal path must pin exact buffer indices. Wrong indices =
  silent garbage. Confirm against Phosphor.h and assert in debug.
- **Threadgroup uniformity.** Match MS's `dispatchThreads` (non-uniform
  threadgroups) so edge tiles aren't dropped/doubled.
- **Two hosts, one core — verify no behavioral drift** between the MTKView path
  and the MS path (the parity GPU-capture test is the guard).
- **PlaybackClock re-homing** off MetalSprockets without changing timing.
- **Effort: XL.** Largest piece is the agnostic frame loop + residency +
  billboard; the pipeline cache, the MTKView host, and the re-homed MS host in
  PhosphorSupport are smaller but each new.
```
