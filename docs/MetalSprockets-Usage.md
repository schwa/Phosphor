# MetalSprockets usage audit

Reviewed August 2026 against the MetalSprockets guidance, for issue #23.

## The headline

**Phosphor doesn't use MetalSprockets as a rendering DSL.** It uses it as a
frame-loop host. Everything in `Packages/PhosphorSupport/Sources/PhosphorMetalSprockets`
is a bridge: an `EmptyElement` with `.onWorkloadEnter` that pulls the command
buffer and drawable out of the environment and hands them to PhosphorKit's
raw-Metal `PhosphorRenderer`, which creates its own encoders.

That's deliberate and documented — PhosphorKit is MetalSprockets-free by
design, and `PhosphorView` has to work without it. But it means most of this
issue's checklist doesn't apply: there is no `RenderPass`, no
`RenderPipeline`, no `Draw`, and no `.parameter(…)` anywhere in the app.

What Phosphor actually gets from MetalSprockets is the `RenderView` frame
loop, `FrameTimingStatistics`, the MTKView configuration modifiers
(`metalColorPixelFormat`, `metalFramebufferOnly`, `metalClearColor`), and the
environment plumbing for the command buffer and drawable.

## Checklist

| Item | Finding |
|---|---|
| `@MSState` vs `@State` vs `@Observable` | No `@MSState` in the codebase, correctly. The two things that must survive across frames — `PhosphorRenderer` (for its pipeline-state cache) and `UpscaleTarget` — are `@State` on the SwiftUI view, which is the right home given they're created before the element tree exists. |
| Body purity | **One exception, see below.** |
| Element composition | `Group { render; if let offscreen { upscale } }` — a flat two-element sequence with a conditional. Nothing worth hoisting; both are already their own `Element`s. |
| `onSetupEnter` vs `onWorkloadEnter` | Only `onWorkloadEnter` is used, and only for genuinely per-frame work (encode a frame; tick the playback clock). There is no one-time GPU setup in the element tree to put in `onSetupEnter` — the pipeline-state cache lives in `PhosphorRenderer`. |
| `@ElementBuilder` on helpers | `PhosphorMetalSprocketsView.content(context:drawableSize:)` deliberately *isn't* annotated: it does arithmetic and a texture lookup that a result builder won't allow inline, and returns `try Group { … }` explicitly. Annotating it would force that logic back into the caller. |
| Reflection / bind-by-name | Not applicable. No `RenderPipeline`, so no reflection to bind through. `PhosphorRenderer` sets its own buffers by index, which is the correct trade for owning the encoders. |
| Pipeline-state caching | Verified. `PhosphorRenderer.computePipelineStates` is keyed by pass id and only rebuilt when `runtime.library` identity changes (`cachedLibrary !== runtime.library`), so a recompile drops the cache and nothing else does. Not MetalSprockets' concern here. |
| `.capture()` for GPU traces | Not exposed. See below. |

## The body-purity exception

`PhosphorMetalSprocketsView.content(_:_:)` calls
`upscaleTarget.texture(device:width:height:)` while building the element tree.
That allocates an `MTLTexture` when the internal render size changes, which is
a side effect in a code path the guidance says should stay pure.

It's there because `MetalFXSpatial` takes its input texture as a *value*, so
the texture has to exist before the element is constructed. Moving the
allocation into `.onSetupEnter` would mean the element tree referenced a
texture that didn't exist yet on the first frame.

Why it's tolerable: the call is memoised on `(width, height)`, so it's
idempotent — repeated evaluation in one frame returns the same texture, and it
only allocates on an actual resize. It is not the kind of side effect that
produces different results when the body is re-evaluated.

If this ever needs to be cleaner, the shape would be an element that owns the
texture in `@MSState`, allocates it in `onSetupEnter`, and contains the
scaler as a child — trading a frame of latency on resize for purity.

## `.capture()`

Not exposed, and probably shouldn't be. `RenderView.capture(true)` bakes a
capture trigger into the view, which means shipping a debug affordance in the
render path and rebuilding to use it. Capturing from outside the app gets the
same trace without that, and works against a running build.

Worth revisiting only if in-app capture of a *specific* frame (say, the frame
after a shader recompiles) turns out to be hard to catch externally.

## No action taken

Nothing here rose to a change worth making. The one deviation from the
guidance is understood, bounded and now written down rather than being
folklore.
