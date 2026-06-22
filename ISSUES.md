# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Step 5: TextureInit.image — load CGImage assets into ping-pong textures

+++
status: closed
priority: medium
kind: feature
labels: effort:m
depends: 46
created: 2026-06-18T20:01:51Z
updated: 2026-06-19T16:11:24Z
closed: 2026-06-19T16:11:24Z
+++

The asset-resolution path is wired up to the runtime (host injects `[String: PhosphorAsset]` into `PhosphorView`), but the materializer doesn't yet honor `TextureInit.image(name:)` — all textures start zero-filled.

Implementation:
- Plumb `assets: [String: PhosphorAsset]` through `PhosphorView -> PhosphorRuntime`.
- In `PhosphorRuntime.allocate`, after creating an MTLTexture, if `spec.initial == .image(name)`, look up the asset, upload the CGImage's bytes to the texture (via an MTLBlit or MTKTextureLoader).
- For ping-pong resources: copy the same initial contents into both halves of the pair.
- Add a test that loads a tiny known-color CGImage and verifies the first frame's iChannel0 sample matches.

Diagnostic case to handle: missing name -> emit a non-fatal `PhosphorDiagnostic` and zero-init the texture.

- `2026-06-19T16:11:24Z`: Implemented in commit dd0f2d00 'Phosphor 2: image asset loading via MTKTextureLoader'.
- `2026-06-19T16:11:24Z`: PhosphorAsset value type carries name + raw bytes.
- `2026-06-19T16:11:24Z`: PhosphorRuntime accepts assets at init/update and honors TextureInit.image(name:) in allocate() by handing the bytes to MTKTextureLoader and blitting the decoded texture into the pre-allocated private-storage target (both halves of a ping-pong pair).
- `2026-06-19T16:11:24Z`: PhosphorBundleDocument reads the assets/ subdirectory of a .phosphord bundle into [String: PhosphorAsset]; PhosphorAssetStrip provides a drop target + thumbnails.
- `2026-06-19T16:11:24Z`: Missing-asset case surfaces as PhosphorDiagnostic.missingAsset and zero-fills the texture so the shader keeps rendering.

---

## 2: Step 6: user uniforms — auto-generated struct + UI controls

+++
status: closed
priority: medium
kind: none
created: 2026-06-18T20:02:05Z
updated: 2026-06-18T20:21:01Z
closed: 2026-06-18T20:21:01Z
+++

The data model already defines `UniformDecl`, `UniformKind`, `UniformValue`, `UniformUIHint`. The header builder emits a `struct UserUniforms` typedef. But the values never flow:

1. The host UI doesn't render any controls.
2. The runtime's userUniformsBuffer is sized but never written.
3. `UniformValue`s declared in the env never reach the GPU.

Implementation:

- `2026-06-18T20:02:05Z`: Define a wire layout for `UserUniforms` matching the auto-generated MSL struct, including correct MSL padding for float3/float4. `PhosphorHeader` emits the typedef; the runtime mirrors that layout in a Swift function that packs an ordered `[UniformDecl]` + values dict into the buffer.
- `2026-06-18T20:02:05Z`: Host UI: `PhosphorView` exposes a `@Binding values: [String: UniformValue]` (or owns its own `@State` keyed by name with defaults from the env). For each `UniformDecl`, render the right SwiftUI control by `UniformUIHint` (`Slider`, `ColorPicker`, `Toggle`, vector field).
- `2026-06-18T20:02:05Z`: `PhosphorRuntime.writeUserUniforms` packs values + memcpys into a fresh `MTLBuffer` each frame (same per-frame-alloc dodge as built-in Uniforms; cross-reference the latent race issue).
- `2026-06-18T20:02:05Z`: Test that round-trips a small uniform set through the GPU and reads back via a single-pixel render.
- `2026-06-18T20:21:01Z`: Implemented. UserUniformsLayout computes MSL-correct field offsets/sizes/alignment for an ordered [UniformDecl] and packs a [String: UniformValue] dict into a buffer. PhosphorRuntime.writeUserUniforms allocates a fresh MTLBuffer per frame (same per-frame-alloc dodge as built-in uniforms; tracked by #6) and packs values + declared defaults. PhosphorView keeps a [String: UniformValue] state dict seeded from the env's defaults and renders a control per UniformDecl via UniformControl (Slider for .float/.int, ColorPicker for .color, Toggle for .bool, component-rows for .vector). Plasma demo wired up with two sliders + a color picker to prove the round trip works end-to-end. 6 new layout tests + existing test suite all pass (38 total).

---

## 3: Step 7: TOML front-matter parser

+++
status: closed
priority: high
kind: none
created: 2026-06-18T20:02:15Z
updated: 2026-06-18T20:12:51Z
closed: 2026-06-18T20:12:51Z
+++

The whole "data-driven" promise relies on this: a single `.metal` string carries its own environment in a `/* phosphor:environment ... */` block at the top of the file. Today `PhosphorEnvironment` is built only from Swift literals.

Implementation:
- Pick a Swift TOML library (`TOMLKit` is the strongest candidate — pure Swift, Decodable, actively maintained).
- Parser: `func parsePhosphorSource(_ source: String) -> (PhosphorEnvironment?, [PhosphorDiagnostic])`.
- Strip the fenced TOML block from the top of the source (we already have `SourceAssembler.stripFrontMatter`).
- Decode the TOML body into `PhosphorEnvironment` via Decodable. The current `Codable` impls should mostly Just Work; verify the inline-table / array-of-tables shape from the design doc round-trips.
- Wire it into `PhosphorView`: if env is nil, infer from `source`; otherwise honor the explicit env argument. Probably split into a `PhosphorView(source:)` convenience that parses, and a `PhosphorView(environment:, source:)` raw form.
- Add the docs example from §4 of Phosphor2.md as a test fixture; verify the resulting env equals the equivalent Swift literal.

- `2026-06-18T20:12:51Z`: Implemented. TOMLKit parses /* phosphor:environment ... */ blocks at the top of a source file into a PhosphorEnvironment. Custom Codable conformances on Resource, TextureSize, TextureInit, UniformDecl, UniformValue, and UniformUIHint adapt the model to a hand-friendly TOML shape (string-or-table for unit enum cases, flat kind-discriminator for Resource, kind-driven dispatch for UniformValue). Texture2DSpec, Pass, and PhosphorEnvironment grew custom Codable inits with optional-with-default decoding so omitted fields fall back to sane defaults.

PhosphorView gained a failable PhosphorView(source:) convenience that parses front-matter, surfaces parse + validation diagnostics in the overlay, and forwards the cleaned body to the runtime. GameOfLife is now defined entirely through its embedded front-matter block.

7 new tests in FrontMatterTests cover: no front-matter, single-pass, the Phosphor2.md §4 multi-buffer + uniforms example, TOML syntax errors, validation errors propagating, top-of-file requirement, and optional-field defaults.

---

## 4: Step 8: FlipTiming.immediate — within-frame flip semantics

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-06-18T20:02:28Z
updated: 2026-06-18T22:06:31Z
+++

`Texture2DSpec.flipTiming` is in the data model with two cases:
- `.endOfFrame`: Shadertoy semantics, what's implemented. Later passes in the same frame see *last* frame's contents.
- `.immediate`: flip right after the writing pass; later passes in the same frame see *this* frame's just-written contents.

`.immediate` is not implemented (parity is currently global to the frame, derived from `uniforms.frame % 2`).

Implementation:
- `.immediate` requires inter-dispatch synchronization within a single command buffer. Pure compute encoder serializes dispatches but doesn't synchronize memory between them without a barrier. Either insert a `memoryBarrier(scope:)` between dispatches that read and write to the same resource, or split the work into separate compute encoders with a fence.
- Parity tracking has to become per-dispatch, not per-frame. The element walks passes in order; for each `.immediate` resource, the parity flips between its writing pass and the next pass that reads it.
- Probably needs a precompute pass that figures out, for each `(pass, resource)` read or write, which parity to use — then channel arg buffers are picked per-pass-per-resource, not per-frame.
- This is the change that makes the parity table per-pass-per-resource, which also unblocks the cross-resource limitation from issue #4.

---

## 5: Cross-resource channel parity is incorrect for multi-buffer pipelines

+++
status: closed
priority: low
kind: bug
labels: effort:m
created: 2026-06-18T20:02:41Z
updated: 2026-06-18T22:29:02Z
closed: 2026-06-18T22:29:02Z
+++

Today `PhosphorRuntime.rebuildChannelBuffers` precomputes two argument-buffer variants per pass (A and B), where the parity in the variant name refers to the pass's OWN output resource. When channel slots reference a different resource, we assume that resource shares the pass's parity.

This is correct for self-feedback (one pass reads + writes the same ping-pong resource — the Game of Life case). It is wrong for true Shadertoy-style multi-buffer pipelines where:
- Pass `bufA` writes `bufA` (ping-pong A)
- Pass `image` reads `bufA` and writes `image`

Here `image` parity is irrelevant; the question is which `bufA` half to read. Today `image`'s channel buffer for parity-A binds `bufA.readTexture(currentIsA: true)`, which is correct only when both resources are in lockstep.

Fix when this becomes an actual problem (Shadertoy port that uses multiple ping-pong buffers):
- Build a parity table per-pass-per-resource at materialization, indexed by the cartesian product of parities of all resources the pass touches. For N ping-pong resources that's 2^N buffers per pass; manageable for N<=4.
- OR: drop precomputed buffers and switch to per-frame rebuild but with proper triple-buffering to dodge the in-flight-read race that originally caused the page faults.

Tracked separately from `FlipTiming.immediate` (#4) but tightly related — that change forces a similar restructuring of the parity model.

- `2026-06-18T22:29:02Z`: Fixed. PhosphorRuntime.writeChannelBuffers now picks each channel slot's texture based on the *sampled resource's* parity, not the reading pass's. Self-feedback (e.g. Game of Life) still uses readTexture for last-frame data; upstream-pass-in-the-same-frame reads now use writeTexture so they see the just-written data with no one-frame lag.

The buffers are also allocated fresh per frame (closes the parity precompute table approach) which sidesteps the in-flight read race that motivated the original precompute (the channel-buffer half of #6).

Verified with Examples/ParityProbe.metal: a two-pass shader where bufA alternates red/green every 30 frames and image samples bufA. After the fix, the right-half diagnostic is solid yellow (correct parity); before, it was strobing blue at every parity flip.

No barriers needed: MetalSprockets emits one MTLComputeCommandEncoder per ComputePass, and inter-encoder ordering within a command buffer is serial.

---

## 6: Latent race: Uniforms / UserUniforms MTLBuffer rewritten while GPU reads previous frame

+++
status: closed
priority: low
kind: bug
labels: effort:m
created: 2026-06-18T20:02:53Z
updated: 2026-06-18T22:30:51Z
closed: 2026-06-18T22:30:51Z
+++

`PhosphorRuntime.writeBuiltinUniforms` currently allocates a fresh `MTLBuffer` per frame for the built-in uniforms — correct, but wasteful (one MTLBuffer alloc per frame). When user uniforms get wired up (#2), the same pattern will apply.

The original implementation reused a single `MTLBuffer` and memcpy'd into it each frame. That caused intermittent GPU page faults around frame 60 — the previous frame's GPU work was still reading the buffer when the CPU wrote frame N+1's values into it. The per-frame allocation works around this safely but at allocator cost.

Right answer: triple-buffer with a frame index that advances per frame, write into the slot that's not in flight. Standard Metal idiom; mirrors how the framework itself handles per-frame state.

Affects:

- `2026-06-18T20:02:53Z`: `PhosphorRuntime.uniformsBuffer` (today)
- `2026-06-18T20:02:53Z`: `PhosphorRuntime.userUniformsBuffer` (after #2)
- `2026-06-18T20:02:53Z`: Possibly the channel argument buffers if #5 forces per-frame rebuild.
- `2026-06-18T22:30:51Z`: Closing in favor of #28 (perf audit), which tracks the per-frame buffer allocation along with other perf items as a coordinated effort. The original race scenario is no longer a correctness bug — writeBuiltinUniforms, writeUserUniforms, and writeChannelBuffers all allocate fresh MTLBuffers per frame, sidestepping the in-flight read race entirely. Triple-buffering remains a nice-to-have optimization.

---

## 7: Stretch: in-app editor UI for environment metadata

+++
status: closed
priority: low
kind: feature
labels: effort:xl
created: 2026-06-18T20:03:03Z
updated: 2026-06-21T05:55:04Z
closed: 2026-06-21T05:55:04Z
+++

Stretch goal from §7 of Phosphor2.md. Not required for 1.0.

A SwiftUI inspector that lets a user, at runtime, edit:
- The list of resources (id, size, format, pingPong, flipTiming, initial).
- The list of passes (id, inputs[].name + resource, output, enabled).
- The list of uniforms (kind, default, ui hint).
- The output ResourceID.

Changes to the document trigger `runtime.update(...)` which recompiles affected passes. Combined with the snippet editor (already in Phosphor 1, port forward), this gives you a full live shader playground.

Probably belongs in the demo app, not in PhosphorSupport — Support stays headless. The editor view binds to the same `PhosphorEnvironment` value the runtime is consuming.

---

## 8: GoL (and any frame-0-seeded shader) goes black after window resize

+++
status: closed
priority: medium
kind: bug
labels: effort:s
created: 2026-06-18T20:05:43Z
updated: 2026-06-18T22:36:29Z
closed: 2026-06-18T22:36:29Z
+++

Repro: launch the Game of Life demo, watch the cells evolve, resize the window. The screen goes black and stays black.

Why it happens:
- Per the Phosphor 2 design (§2.2 of Phosphor2.md), `.drawable`-sized textures are reallocated and zero-filled when the drawable size changes. Feedback state is intentionally discarded; this matches Shadertoy.
- GoL's seeding branch fires only when `uniforms.frame < 1.0`. By the time the user resizes, frame is in the thousands — the seed branch never re-fires. With zero-filled iChannel0 and the B3/S23 rule, every cell stays dead forever.

The design doc explicitly calls out `.fixed(w, h)` as the escape hatch when a demo can't tolerate resize-discarded state. But "can never re-seed after resize" is a sharp edge any shader that uses `frame == 0` as a sentinel will fall into.

Options to consider:
1. Reset `uniforms.frame` to 0 on drawable resize (breaks time monotonicity, surprising).
2. Expose a separate `uniforms.epoch` or `uniforms.framesSinceReset` that the runtime resets to 0 on each texture reallocation.
3. Encourage authors to use a different sentinel for seeding — e.g. a uniform-buffer dirty flag set by the runtime when textures are freshly allocated.
4. Document the gotcha and leave shaders to pin `.fixed(w, h)` if they care. Cheapest, least invasive.

(2) feels right: it's an additive uniforms field, doesn't change existing semantics, and gives authors a clean "this is a fresh canvas" signal.

Affects every demo that uses a frame-0 seed: GameOfLife. Will affect any reaction-diffusion / fluid sim once we have them.

- `2026-06-18T22:36:29Z`: Fixed. Added a new `uniforms.resized` field (UInt32) to BuiltinUniforms and the synthesized MSL Uniforms struct. PhosphorRuntime sets a resizedFlag whenever any texture is (re)allocated in ensureTextures, and writeBuiltinUniforms forwards that flag as `resized` and clears it. Shaders that need to (re)seed feedback state should test `uniforms.frame < 1.0 || uniforms.resized != 0u`. GameOfLife.metal updated to use the new pattern; the system prompt mentions `resized` so generated shaders pick it up. Verified by resizing the GoL window: the simulation reseeds cleanly instead of going black.

---

## 9: Memory grows over time while running Game of Life demo

+++
status: closed
priority: medium
kind: bug
labels: effort:m
created: 2026-06-18T20:05:56Z
updated: 2026-06-21T04:49:44Z
closed: 2026-06-21T04:49:44Z
+++

Reported: while the Game of Life demo runs, app memory usage grows continuously (no plateau). Needs investigation — could be leak, could be expected (caches), could be observation-system retention.

Suspects, in rough likelihood order:
1. Per-frame MTLBuffer allocations in `PhosphorRuntime.writeBuiltinUniforms` are released (no retain in our code) but Metal's allocator may pool them. Run with leaks(1) / malloc-stack-logging / Instruments "Allocations" to confirm whether actual leaks vs allocator caching.
2. `@Observable PhosphorRuntime` mutating its dictionaries each frame may cause observation-registration churn. Worth checking under Instruments.
3. The shader runtime-compiled `MTLLibrary` and `MTLComputePipelineState` are recreated every time we `update(environment:source:)` — should only fire on env/source change, but verify with a counter.
4. GPU residency tracker / Metal logging buffer if MS_METAL_LOGGING=1 is on — known to grow.

Action: profile under Instruments Allocations + Leaks for ~60 sec of steady-state GoL playback, attribute growth to a category, then fix or close as expected.

- `2026-06-21T04:49:44Z`: Not reproducing in current builds — memory reaches a plateau during steady-state Game of Life playback. Closing as not reproducible; reopen with an Instruments Allocations trace if it recurs.

---

## 10: Colorise TOML in front matter too

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-06-18T20:45:57Z
updated: 2026-06-19T16:58:04Z
closed: 2026-06-19T16:58:04Z
+++

Currently TOML syntax highlighting isn't applied to front matter blocks. Extend colorisation to TOML in front matter.

- `2026-06-19T16:58:04Z`: Done. MetalSourceView now parses the front-matter TOML body with tree-sitter-toml and applies token colors (bare keys, strings, numbers, booleans, table headers). Also styles all C++ comments green + italic so the front-matter block still reads as a comment despite the inner coloring.

---

## 11: Picker to show ANY in-use texture instead of just output texture

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m
created: 2026-06-18T21:32:32Z
updated: 2026-06-19T16:15:30Z
closed: 2026-06-19T16:15:30Z
+++

Add a picker UI to select and display any texture currently in use, not just the output texture.

- `2026-06-19T16:15:30Z`: Done. Toolbar picker in PhosphorEditorBody lets the host choose which resource gets blitted to the drawable. 'Output' (the default) follows environment.output; other entries select an intermediate resource by id. PhosphorPipeline takes a displayedResource: ResourceID? override and falls back to the declared output when the chosen id isn't allocated. Disabled when the environment has fewer than two resources.

---

## 12: Mouse uniforms (mouse/mouseButtons/mouseClickOrigin) are never updated

+++
status: closed
priority: medium
kind: feature
labels: effort:s
created: 2026-06-18T21:43:30Z
updated: 2026-06-18T23:42:51Z
closed: 2026-06-18T23:42:51Z
+++

The kernel sees `uniforms.mouse` (xy in pixels), `uniforms.mouseButtons` (bitmask), and `uniforms.mouseClickOrigin` (xy of last press). These are declared in the BuiltinUniforms struct and wired all the way through to the shader, but the host never assigns them — they are always zero.

To make them work:
- Add SwiftUI gestures to the PhosphorView preview (DragGesture for press-and-drag, onContinuousHover for hover, an NSEvent monitor on macOS for right/middle/scroll if we want them).
- Store the live mouse position, button mask, and click-origin in PhosphorView's @State.
- Plumb them into BuiltinUniforms when building the per-frame uniforms.
- Consider whether the values should be in pixels (matching uniforms.resolution) or normalized 0..1; pixels match the existing field semantics.
- The fade demo would be a good test: scrub the mouse around and see the column follow it.

Shadertoy semantics for reference: iMouse.xy is the current position while held, iMouse.zw is the click origin with sign indicating button state. We chose to split this into 3 separate fields for clarity; preserve those semantics.

- `2026-06-18T23:42:51Z`: Done. PhosphorView now tracks mouse state via @State (position, button mask, click origin) and feeds it into BuiltinUniforms each frame.

Tracking:
- onContinuousHover updates mousePosition (mouse-moved-with-no-button).
- DragGesture(minimumDistance: 0) handles click+drag: on first press it records mouseClickOrigin, sets bit 0 of mouseButtons; on end it clears bit 0.
- View-space points are converted to pixel coordinates matching uniforms.resolution by ratio of cached drawableSize / viewSize. onGeometryChange caches viewSize.

Tests live in Examples/MouseProbe.metal: a soft white glow follows the cursor; background turns red while a button is held; a blue glow appears at the recorded click origin during a drag. Confirmed working.

---

## 13: Add a 'New Shader From Prompt…' preset menu

+++
status: closed
priority: low
kind: feature
labels: effort:s
created: 2026-06-18T21:45:48Z
updated: 2026-06-19T01:01:01Z
closed: 2026-06-19T01:01:01Z
+++

Add a menu (toolbar split-button or File submenu) that exposes a curated set of starter prompts. Clicking one fills the Generate panel's prompt field with the preset text and either fires generation immediately or just opens the panel so the user can tweak first.

Suggested initial preset list:
- Game of Life
- Plasma
- Worley noise / cell pattern
- Reaction-diffusion
- Mandelbrot / Julia set
- Spiral galaxy
- Falling Matrix code
- Animated checkerboard
- Tunnel / fly-through
- Audio-style waveform
- Polar coordinate fractal
- Marching squares contours

UX details to decide when implementing:
- Toolbar split button vs. a SwiftUI Menu next to Generate? Probably a separate 'Templates' menu.
- Open the panel pre-filled (low surprise) or generate-then-show-source (high reward, can be jarring on slow models)?
- Should the prompt history include the preset text or strip it? Probably include — they're real prompts.

---

## 14: Layout toggle: side-by-side vs. overlay (code on top of preview)

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-18T21:46:29Z
updated: 2026-06-20T23:35:42Z
closed: 2026-06-20T23:35:42Z
+++

Add a toggle (toolbar item or View menu) that switches the document layout between two modes:

1. **Side-by-side** (current). HSplitView with the code pane on the left and the live preview on the right. Both visible at all times.

2. **Overlay**. The preview fills the entire window. The code text is overlaid on top of the preview (translucent background, monospaced, syntax-highlighted). Lets the user see the effect at full size while still editing.

UX details to decide when implementing:
- Toolbar toggle button ( / ) probably the right spot.
- Persist the choice per-window or via @AppStorage app-wide? Probably app-wide.
- Overlay mode needs background dimming / blur on the text so it stays readable over bright shader output.
- Overlay mode should still show the uniforms panel and the diagnostics overlay; need to think about placement.
- Should the editor still be editable in overlay mode? Probably yes \u2014 same TextEditor binding.

---

## 15: Generation: ask the model to document each kernel

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-18T21:49:10Z
updated: 2026-06-18T23:14:31Z
closed: 2026-06-18T23:14:31Z
+++

Update the ShaderGenerator system prompt so the model emits a documentation comment above each `kernel void` declaration, describing what the kernel does in 1-3 sentences.

Format suggestion (use whatever the model produces consistently):

```metal
/**
 * Brief: Computes a Worley noise pattern by finding the nearest of N random points.
 *
 * Reads:
 *   - iChannel0: previous frame for temporal smoothing.
 *
 * Writes: outTexture
 *   - .rgb: greyscale noise value.
 *   - .a: 1.0
 */
kernel void image(...) { ... }
```

UX details to decide:

- `2026-06-18T21:49:10Z`: Single short comment vs. structured doc block? Probably let the model choose, but show one structured example in the system prompt.
- `2026-06-18T21:49:10Z`: Should multi-pass shaders document each kernel separately? Yes \u2014 they're often quite different.
- `2026-06-18T21:49:10Z`: Trade-off: more comments = more output tokens = slower + costlier generation. Probably worth it.
- `2026-06-18T23:14:31Z`: Done. Added a DOCUMENT EACH KERNEL section to the ShaderGenerator system prompt instructing the model to write a 1-3 sentence doc comment above every kernel void declaration describing what it does, which channels it reads, and what it writes. Includes a /// example. Multi-pass shaders document each kernel separately. No runtime/code changes — just the prompt.

---

## 16: Port Phosphor 1 example snippets into Examples/

+++
status: closed
priority: medium
kind: task
labels: effort:l
created: 2026-06-18T21:52:41Z
updated: 2026-06-19T01:19:44Z
closed: 2026-06-19T01:19:44Z
+++

The original Phosphor 1 demo (`MetalSprocketsExamples/.../PhosphorDemo/Examples/`) ships a curated library of 19 shadertoy-style snippets:

- Plasma
- Fire
- Heart
- Checkerboard
- Cityscape
- FractalKaleidoscope
- FractalPlant
- HelloTriangle
- HSVRaymarch
- IterativeTrig
- NeonLamp
- NoiseFlow
- RaymarchingSphere
- ReactionDiffusion
- TerrainRiver
- VoronoiCells
- WaterRipples
- TwiglGeek
- BrokenShader (intentionally broken)

Port these to Phosphor 2 form: rewrite each as a full `kernel void` with the canonical signature and add a TOML front-matter block. Drop into the top-level `Examples/` directory alongside the existing six demos (GameOfLife, Plasma, Bloom, Accumulate, Noise, SolidColor).

This is mostly mechanical:
- Strip the Shadertoy-style `mainImage(...)` wrapping; rewrite the body inline as a kernel.
- Replace `fragCoord/iResolution/iTime/iMouse` references with `gid/uniforms.resolution/uniforms.time/uniforms.mouse`.
- Replace `texture(iChannelN, uv)` with `channels.iChannelN.read(uint2(coord))`.
- For each, declare appropriate resources/passes/uniforms in front-matter.

A few are non-trivial (RaymarchingSphere has heavy math, ReactionDiffusion is multi-pass with ping-pong, NoiseFlow may need texture inputs we don't have yet). Tackle the simple ones first and leave the rest for follow-up.

Keep our existing Plasma demo separate \u2014 the Phosphor 1 "Plasma" is a different effect.

Once ported, update Examples/ in the README / docs so users can discover them.

- `2026-06-19T01:19:44Z`: Done. 17 of the original 19 Phosphor 1 example snippets ported into Examples/: Checkerboard, Cityscape, Fire, FractalKaleidoscope, FractalPlant, Heart, HelloTriangle, HSVRaymarch, IterativeTrig, NeonLamp, NoiseFlow, PlasmaClassic, RaymarchingSphere, ReactionDiffusion, TerrainRiver, VoronoiCells, WaterRipples.

Skipped:
- BrokenShader (intentionally broken; not useful as a demo).
- TwiglGeek (single-line obfuscated demo with a different preprocessor convention; not worth porting).

To make the port mechanical, the synthesized PhosphorHeader gained a helpers section with the Phosphor 1 Support.h helpers: PI, PI2, vec2/3/4 aliases, F4, rotate2D, rotate3D, fsnoise, fsnoiseDigits, hsv, snoise2D, snoise3D, snoise4D. The Metal compiler dead-codes whatever a given shader doesn't use.

Each ported file keeps the original mainImage(...) function intact and wraps it in a Phosphor 2 kernel that substitutes the parameter names (position = float2(gid), resolution = uniforms->resolution, etc.).

Existing hand-written Plasma.metal stayed; the Phosphor 1 'Plasma' is a different effect, ported as PlasmaClassic.

---

## 17: Microphone audio input as a shader resource

+++
status: closed
priority: low
kind: feature
labels: effort:l
created: 2026-06-18T21:52:56Z
updated: 2026-06-19T00:52:51Z
closed: 2026-06-19T00:52:51Z
+++

Expose live microphone audio to kernels as a sampleable texture (or buffer), matching Shadertoy's microphone channel concept.

Shadertoy convention: bind the mic as an `iChannelN` and sample with `texelFetch(iChannelN, ivec2(x, 0), 0).x` for the FFT row and `.y` for the waveform row. We'd do the analogous thing with our channel rack.

Implementation sketch:
- Add a new resource kind to PhosphorEnvironment, e.g. `Resource.microphone` (or expand `TextureInit` with `.microphone`).
- Host code uses AVAudioEngine to capture the input device. AVAudioPCMBuffer -> vDSP FFT -> a small (e.g. 512x2) Metal texture: row 0 = magnitude spectrum, row 1 = raw waveform.
- Same channel-arg-buffer plumbing as image inputs; no kernel signature change.
- Front-matter: `spec = { source = "microphone" }` or similar.
- Sandbox: the app needs the audio-input entitlement and NSMicrophoneUsageDescription in Info.plist; first use prompts for permission.
- Add a Settings toggle for whether shaders can request mic access (off by default), so non-audio shaders never trigger the prompt.

Stretch:
- Audio-only resources (no texture) for shaders that want a 1D waveform.
- Sample rate / FFT size knobs in Settings.
- File input as an alternative to live mic.

Test demos to port from Shadertoy: classic audio visualizers (FFT bars, oscilloscope, beat-reactive bloom). The Bloom demo could pick brightness from audio level.

- `2026-06-19T00:52:51Z`: Closed by the #33/#34/#35/#36 sub-issue chain. Microphone audio capture, FFT spectrum, and the AudioProbe demo are all in place. waveform (1024 floats) and spectrum (512 floats) are now first-class Uniforms fields accessible from any kernel.

---

## 18: Render shader output onto arbitrary geometry (cubes, teapots, ...)

+++
status: open
priority: low
kind: feature
labels: effort:xl
created: 2026-06-18T21:53:14Z
updated: 2026-06-18T22:06:31Z
+++

Currently the final image is blitted to the drawable via a fullscreen `TextureBillboardPipeline`. The shader output is always rectangular and screen-aligned. We should let the user pick the *surface* on which the shader is sampled \u2014 cube, teapot, sphere, custom mesh \u2014 with a camera around it.

Mental model:
- The compute passes still write to a 2D texture (no change).
- The final blit becomes a textured-mesh render pass: vertex shader transforms a mesh by a camera matrix; fragment shader samples the shader output texture using either standard UVs (planar map onto mesh) or another mapping (triplanar, equirectangular for spheres, etc).
- The user picks the geometry from a small built-in library (Quad / Cube / Sphere / Teapot / Suzanne / ...) plus eventually arbitrary glTF / USDZ load.
- Camera controls: orbit (`Interaction3D` from MetalSprockets / .interactiveCamera).

Where to put it:
- A new `display` section in the front-matter (`display = { geometry = "cube", uvMapping = "box" }`) so the choice is per-shader.
- Or app-level (View menu: "Display on..." with the geometry list), so the user can A/B the same shader against different surfaces.
- Probably both: front-matter sets the default; UI lets you override.

MetalSprockets has primitives we can lean on:
- BlinnPhong/Lambertian/Flat pipelines (textured mesh rendering).
- BouncingTeapotsDemo / SkyboxDemo as reference for camera + mesh.
- Trekanten / SwiftMesh for loading model files.

Trickier bits:
- Lighting. Do we light the mesh, or treat the shader output as emissive (no shading)?
- UV mapping for non-trivial geometry (a teapot has UVs but they're famously awful).
- Depth and back-face culling for transparent shaders.

Start with: Quad (current), Cube (planar-per-face), Sphere (equirectangular). That covers most desire.

---

## 19: Show all Anthropic models in the Generate panel picker

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-18T21:54:20Z
updated: 2026-06-18T22:58:13Z
closed: 2026-06-18T22:58:13Z
+++

Today the Generate panel exposes a single Anthropic option (Claude Opus). We hardcoded `claude-opus-4-5` in the ShaderGenerator. Expose the other Anthropic models so the user can trade off quality vs. cost vs. latency per generation.

Implementation sketch:
- Replace the single `GenerationModel.anthropicClaudeOpus` case with a parameterised one (`.anthropic(modelName: String)`) or expand the enum with per-model cases (`.anthropicOpus`, `.anthropicSonnet`, `.anthropicHaiku`).
- Keep an authoritative list of currently-released Anthropic models somewhere central (probably in PhosphorSupport) so we only update one place when Anthropic releases new ones.
- The Generate panel picker lists them under an "Anthropic" submenu (or as flat entries with prefixes \u2014 picker menus get unwieldy fast).
- Default to the cheapest fast model (Haiku); user can opt up.
- Persist the choice via @AppStorage like we do today.

Notes:
- Anthropic adds/renames models often; consider fetching the model list from the API at runtime rather than hardcoding, behind a "Refresh model list" button in Settings.
- The model name string lives in our settings; the Anthropic key lives in the Keychain. Keep that split.
- Token-usage display would be nice eventually \u2014 LanguageModelSession exposes a .usage property after each respond. Out of scope here.

- `2026-06-18T22:58:13Z`: Done. GenerationModel.anthropicClaudeOpus replaced with a parameterized .anthropic(AnthropicModel) case. AnthropicModel is a tiny struct with id + displayName; the curated catalogue (Opus 4.5, Sonnet 4.5, Haiku 4.5) lives on AnthropicModel.all and is easy to update.

GenerationModel.all returns the full list (on-device, PCC, three Anthropic models). The picker uses that. raw-value persistence migrates: 'anthropicClaudeOpus' from earlier builds doesn't decode anymore, falls back to On Device — acceptable hiccup since the user can pick again.

ShaderGenerator routes the chosen AnthropicModel.id to FoundationModelBackends' AnthropicLanguageModel(apiKey:model:).

Dynamic model-list fetching from the API and per-pickable model display under a submenu are still possible follow-ups but not blocking.

---

## 20: Move uniforms-panel toggle into the toolbar

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-18T21:57:15Z
updated: 2026-06-18T22:46:32Z
closed: 2026-06-18T22:46:32Z
+++

Today the uniforms panel (top-right overlay on the preview) has its own little switch toggle in its header. Move that toggle into the document window's main toolbar so it's discoverable next to Generate and Phosphor.h.

Implementation:

- `2026-06-18T21:57:15Z`: PhosphorView currently owns @State showUniformsPanel: Bool. Pull it up to PhosphorDocumentView (or expose a binding) so the toolbar can drive it.
- `2026-06-18T21:57:15Z`: Add a ToolbarItem with a slider/sparkles/control-style icon \u2014 maybe slider.horizontal.3 \u2014 wired to that binding.
- `2026-06-18T21:57:15Z`: Remove the inline switch from the uniforms-panel header (the header still shows the 'Uniforms' label).
- `2026-06-18T21:57:15Z`: Disable the toolbar toggle when the current document has no uniforms declared, so it's not a dead control on those shaders.
- `2026-06-18T21:57:15Z`: Persist across documents via @AppStorage so muscle memory carries between windows.
- `2026-06-18T22:46:32Z`: Done. PhosphorView's showUniformsPanel state moved out as an @AppStorage value (phosphor.ui.showUniformsPanel) so it persists app-wide. The uniforms overlay no longer renders its own toggle in its header — there's just the 'Uniforms' label now. PhosphorDocumentView gained a Toolbar item bound to the same @AppStorage key with a slider.horizontal.3 icon; the toggle is disabled when the current shader has no uniforms declared, with an explanatory help tooltip.

---

## 21: Generated shaders are often upside down — teach the model our coordinate system

+++
status: closed
priority: medium
kind: bug
labels: effort:xs
created: 2026-06-18T22:04:00Z
updated: 2026-06-18T22:41:40Z
closed: 2026-06-18T22:41:40Z
+++

Many generated shaders come out vertically flipped. The model is defaulting to GLSL/Shadertoy conventions where Y=0 is at the bottom of the screen, but our compute kernels use Metal's `gid` directly, where Y=0 is at the top.

Symptoms:
- A 'sun on the horizon' shader puts the sun at the bottom edge instead of the top.
- 'Falling rain' or 'falling Matrix code' moves upward.
- Anything that subtracts from `uniforms.resolution.y - gid.y` to flip.

Fix:
- Add explicit guidance to the ShaderGenerator system prompt: "In Phosphor, gid.y = 0 is at the TOP of the screen and gid.y = resolution.y - 1 is at the bottom. This is opposite to GLSL / Shadertoy / WebGL."
- Show one corrected example: an upward-moving particle, a sun at the top.
- Mention common gotchas: Shadertoy ports must invert Y (`fragCoord.y = resolution.y - gid.y` or just remove their inversion).
- Consider also mentioning aspect ratio (uv.x / uv.y after dividing by resolution) and how to compute it.

Once added, regenerate a few prompts that previously came out flipped and confirm they're right-side-up.

- `2026-06-18T22:41:40Z`: Fixed. Added a `flipY: Bool` field to PhosphorEnvironment (default false, omitted from TOML when false). When true, PhosphorPipeline passes flipped V coordinates to TextureBillboardPipeline so the final blit is upside down — the kernel can write in GLSL/Shadertoy convention (Y=0 at bottom) and the result lands right-side up.

The system prompt explains both conventions explicitly and tells the model to set flipY when writing Shadertoy-style code. The generation schema (GeneratedShader) gained a matching flipY field. Existing demos (Phosphor convention, Y=0 at top) default to false and render identically to before; Shadertoy ports can paste verbatim and set flipY=true in the front-matter.

---

## 22: SwiftUI audit: idioms, accessibility, perf

+++
status: closed
priority: low
kind: task
labels: effort:m
created: 2026-06-18T22:05:23Z
updated: 2026-06-19T02:33:55Z
closed: 2026-06-19T02:33:55Z
+++

Sweep the SwiftUI surface (PhosphorView, PhosphorDocumentView, GeneratePanel, SettingsView, MetalSourceView, UniformControl) for:

- Idiomatic API use (binding shapes, @Bindable vs @Observable, @State macro patterns).
- Accessibility: VoiceOver labels/hints/traits, Dynamic Type, keyboard nav, focus order.
- Layout robustness: small windows, large fonts, RTL.
- Perf: unnecessary view recomputes, large @State that triggers heavy redraws (the uniforms dict, the AttributedString in MetalSourceView), per-frame work in body.
- 2027-era APIs: anything we should adopt (NavigationSplitView for the doc layout? Inspector? scenePadding? toolbar visibility APIs?).

Use the swiftui-specialist and accessibility-audit skills.

- `2026-06-19T02:33:55Z`: Done as a SwiftUI review pass on 2026-06-18. Findings landed across two commits:

- Extracted @ViewBuilder computed properties into View structs (house rule): UniformControl, PhosphorDocumentView, PhosphorView.
- Migrated SettingsView's TabView to the macOS 27 Tab API (soft-deprecated tabItem).
- Dropped dead code in MetalSourceView (editableBinding).
- Trivial cleanup in GeneratePanel.
- Added #Preview blocks to every standalone-previewable view. PhosphorDocumentView and GeneratePanel can't be previewed because PhosphorMetalDocument needs a URLDocumentConfiguration with no public init.

Follow-ups split into their own issues:
- #45: restructure PhosphorView body into Loading/Error/Running branch views.
- #43: extract the playback clock state machine inside PhosphorView (already filed earlier).

Accessibility and perf bits of the original audit not addressed here; if needed they can be split into focused issues.

---

## 23: MetalSprockets audit: are we using it idiomatically?

+++
status: open
priority: low
kind: task
labels: effort:s
created: 2026-06-18T22:05:34Z
updated: 2026-06-18T22:06:31Z
+++

Sweep PhosphorPipeline.swift, PhosphorRuntime.swift, and PhosphorView.swift for MetalSprockets best practices per the metalsprockets skill:

- @MSState vs @State vs @Observable: are we splitting per-frame state correctly?
- Body purity: any side effects sneaking in? (We had a few during initial development.)
- Element composition: is the ForEach inside the body using @ElementBuilder correctly? Should anything be hoisted to a sub-Element?
- onSetupEnter vs onWorkloadEnter: are we doing one-time work in the right hook?
- @ElementBuilder on helper methods we should be using.
- Reflection: are we binding by-name where we could? (We are, but double-check.)
- Pipeline state caching: the per-pass MTLFunction is good; verify MetalSprockets is caching the pipeline state per function across frames.
- Capture support: should we expose .capture() for GPU traces?

Use the metalsprockets skill.

---

## 24: Run swiftlint + fix violations

+++
status: closed
priority: low
kind: task
labels: effort:s
created: 2026-06-18T22:05:43Z
updated: 2026-06-19T02:39:44Z
closed: 2026-06-19T02:39:44Z
+++

Add a .swiftlint.yml (if not present) and run `swiftlint lint --quiet` over the package + app. Fix violations or document opt-outs.

Particular things likely to come up:
- Force unwrap (`Demo.all.first!` style \u2014 we have one).
- Cyclomatic complexity in the long switches in UniformControl / UniformValue.
- Long files (PhosphorRuntime.swift is getting chunky).
- Type body length / function body length.
- Trailing whitespace / vertical_whitespace.

Use the swift-linting skill.

- `2026-06-19T02:39:44Z`: Done. swiftlint runs clean against the project.

- Added .build / Packages/*/.build exclusions to .swiftlint.yml so SwiftPM build artifacts don't trip line-length checks.
- Fixed two real violations in Phosphor/GeneratePanel.swift (closure_end_indentation, opening_brace, trailing_closure) on the ShaderGenerator.generate(...) call site.
- Repaired a multi-statement-on-one-line build break in PhosphorSupport/Parser/FrontMatter.swift that was introduced by an earlier swiftlint --fix run.

`swiftlint lint` now produces zero violations.

---

## 25: Documentation: DocC + README + Examples README

+++
status: open
priority: medium
kind: documentation
labels: effort:l
created: 2026-06-18T22:05:52Z
updated: 2026-06-18T22:06:31Z
+++

Phosphor 2 has effectively no docs right now. Address three layers:

1. **DocC for PhosphorSupport.** Create a .docc catalog. Tutorials worth writing:
   - Getting Started (open a .metal file, see it render).
   - Writing your first shader from scratch (front-matter format, kernel signature).
   - Multi-pass shaders (Bloom-style).
   - User uniforms with live UI controls.
   - The TOML front-matter reference.
   Doc-comment every public symbol \u2014 we have a lot of bare `public` declarations.

2. **Top-level README.md.** Describe what Phosphor is, install/build, screenshot, link to docs.

3. **Examples/README.md.** One-line description of each shipped demo.

Use the swift-documentation skill.

---

## 26: Shadertoy compatibility audit: what fraction can we run today?

+++
status: open
priority: medium
kind: none
created: 2026-06-18T22:08:22Z
updated: 2026-06-19T16:16:03Z
+++

Survey Shadertoy's API surface against what Phosphor 2 currently supports. Goal: a written gap analysis so we know what to add next to maximise the fraction of Shadertoy shaders that port over with mechanical changes.

Categorise each Shadertoy feature into:
- ✅ supported (works today, possibly with renamed identifiers).
- ⚠ partial (works but with caveats; missing features users will hit).
- ❌ missing (no equivalent yet).

Categories to cover at minimum:

**Uniforms / built-ins**
- iTime, iTimeDelta, iFrame, iFrameRate, iResolution, iDate.
- iMouse (#12).
- iChannelTime[N], iChannelResolution[N].
- iSampleRate.

**Channel input types**
- Image textures (#1).
- Cubemaps.
- 3D volume textures.
- Video.
- Microphone (#17).
- Audio file.
- Keyboard.
- Webcam.
- Buffer A/B/C/D (multi-pass).

**Pass types**
- Image (✅).
- Buffer A/B/C/D (✅ multi-pass; verify all 4 channels).
- Common (shared code prepended to every pass).
- Cubemap.
- Sound.

**Sampler behavior**
- Filter modes (linear/nearest).
- Wrap modes (clamp/repeat).
- VFlip.
- sRGB.

**Output**
- Single fullscreen image (✅).
- HDR / float buffers (✅).
- MRT.

**Language**
- GLSL fragment-shader idioms (we map to MSL compute).
- mainImage(out vec4 fragColor, in vec2 fragCoord) -> our kernel signature.
- Shadertoy-specific built-ins (mod, mix, texture(...), texelFetch(...), texture lookups with bias).
- #define and preprocessor.
- Multiple GLSL versions.

For each ❌ or ⚠, link to the relevant existing issue or note the work required.

Outcome: a markdown table (or a doc section under DocC) summarising what 'a Shadertoy port' costs in 2026 vs. once we close the open issues. Probably motivates the priority order on several existing issues.

---

## 27: Shadertoy compatibility layer: auto-translate Shadertoy GLSL to Phosphor MSL

+++
status: open
priority: medium
kind: none
created: 2026-06-18T22:08:49Z
updated: 2026-06-19T16:16:03Z
+++

Make Phosphor accept Shadertoy source verbatim and translate it to a Phosphor kernel at runtime, so users can paste Shadertoy URLs/snippets directly without manual rewriting.

Two layers, roughly orthogonal:

**Lexical / textual translation.** Detect Shadertoy-shaped source (presence of `mainImage(out vec4 fragColor, in vec2 fragCoord)`) and rewrite it on the way to the compiler:

- Wrap mainImage in a kernel using our canonical signature.
- Rename built-ins: iTime → uniforms.time, iResolution → uniforms.resolution, iFrame → uniforms.frame, iMouse → uniforms.mouse, iTimeDelta → uniforms.timeDelta.
- iChannelN → channels.iChannelN.
- texture(iChannelN, uv) → channels.iChannelN.sample(...).
- texelFetch(iChannelN, ivec2(x,y), 0) → channels.iChannelN.read(uint2(x,y)).
- vec2/vec3/vec4 → float2/float3/float4 (often Just Works under Metal but check).
- mat3/mat4 → float3x3/float4x4.
- Coordinate flip if needed (#21).
- Possibly synthesise a front-matter block for the most common case (single Image pass, no inputs).

**Semantic / dialect differences** (harder):

- GLSL’s implicit float promotion vs Metal's strict typing.
- Different modulo / fmod semantics for negative numbers.
- mix() / lerp() / smoothstep() argument order — same in both, but worth verifying.
- gl_FragCoord starts at (0.5, 0.5), our gid starts at (0, 0).
- mainImage’s fragColor is OUT, our kernel writes via outTexture.write.

**Where it lives.**

- A new `ShadertoyTranslator` in PhosphorSupport. Pure function: `(String) -> (translated: String, diagnostics: [PhosphorDiagnostic])`.
- Invoked from the front-matter parser as a fallback: if no `/* phosphor:environment */` block is found AND the source looks like Shadertoy, translate it and synthesize an environment.

**Testing.**

- Pick 10 popular Shadertoy shaders. Track how many port cleanly via the translator.
- Multi-pass Shadertoy shaders require Buffer A/B/C/D modeling \u2014 explicit `#image` / `#buffer` directives or magic-comment markers.

Related: #26 (Shadertoy audit), #16 (Phosphor 1 examples \u2014 those were also Shadertoy-style).

---

## 28: Use Metal gid-as-global style for kernel thread index

+++
status: closed
priority: medium
kind: enhancement
created: 2026-06-18T22:15:45Z
updated: 2026-06-19T18:10:35Z
closed: 2026-06-19T18:10:35Z
+++

Adopt the Metal style where the grid/thread index is declared as a global variable (e.g. via attribute on a global) rather than passed as a parameter to the kernel function.

- `2026-06-19T18:10:35Z`: Done as part of #50. All 36 examples now declare 'uint2 gid [[thread_position_in_grid]];' at file scope rather than as a kernel parameter. PhosphorHeader doesn't need to do anything to support it — MSL accepts the file-scope attributed global naturally.

---

## 29: Performance audit + tracking

+++
status: open
priority: low
kind: task
labels: effort:l
created: 2026-06-18T22:31:09Z
updated: 2026-06-18T22:31:51Z
+++

Track perf concerns and tuning opportunities across the runtime. Lump small wins together so we can prioritise as a batch rather than litigating each in its own ticket.

**Known items to address or measure:**

1. Per-frame MTLBuffer allocation (was #6).
   - `PhosphorRuntime.writeBuiltinUniforms`, `writeUserUniforms`, and `writeChannelBuffers` each allocate a fresh MTLBuffer every frame to dodge the in-flight read race that originally caused GPU page faults.
   - Working but wasteful: ~360 makeBuffer calls/sec at 60fps with 2 passes.
   - Fix: triple-buffer fixed MTLBuffers with a frame index that advances per frame. Standard Metal idiom.
   - Pre-requisite: a small ring-buffer helper inside PhosphorRuntime.

2. Per-keystroke recompile.
   - MetalSourceView edits trigger PhosphorView's task(id:) to rebuild PhosphorRuntime on every change.
   - Long shaders become choppy under heavy typing.
   - Fix: debounce source changes (e.g. 250ms) before triggering recompile. Optional 'compile now' button.

3. AttributedString re-highlighting on every keystroke.
   - MetalSourceView re-runs tree-sitter on the full source for every change.
   - Fix: incremental parse via tree-sitter's edit/reparse API (`Parser.parse(tree:string:)`), already supported by SwiftTreeSitter.

4. ChannelBindings struct stride / overall layout.
   - Currently 8 bytes per slot (one MTLResourceID). Buffer minimum is 16. Fine, just verify there's no padding-related undefined behavior with very large channelCount.

5. Per-frame Swift array allocations for use-resource lists.
   - `writeChannelBuffers` returns `[ResourceID: [MTLTexture]]` allocated fresh each frame. Probably negligible but verify under Allocations.

6. Profile under Instruments.
   - Run the existing Bloom or ParityProbe demo for 60 seconds.
   - Categorise time/memory: Metal driver, our Swift code, MetalSprockets framework overhead, SwiftUI updates.
   - Look for runaway allocations (cf. the GoL memory growth concern in #9 — may overlap).

Approach:
- Land a baseline measurement first (frame time histogram + Allocations summary) so we have numbers to compare against.
- Pick the top 1-2 wins by measured impact, not by theoretical concern.

---

## 30: Generation: retry once when the produced shader fails to compile

+++
status: closed
priority: medium
kind: none
created: 2026-06-18T23:01:03Z
updated: 2026-06-18T23:38:57Z
closed: 2026-06-18T23:38:57Z
+++

Today, ShaderGenerator does a single pass: prompt the model, take its output, replace document.text. If the result fails to compile (Metal compiler errors), the user sees the error and has to manually re-prompt.

Better: capture the Metal compiler diagnostics on first failure and feed them back to the model with a 'this is what you produced; here are the compiler errors; produce a fixed version' message. One automatic retry usually catches the silly type-mismatch and missing-include style errors (MSL vs GLSL strictness, etc).

Implementation sketch:
- ShaderGenerator.generate(prompt:model:existingSource:) becomes the entry point.
- After the first generation, run the compiler against the produced source. If it succeeds, return as today.
- If it fails, take the PhosphorCompileError + the produced body and start a SECOND LanguageModelSession.respond, with a follow-up prompt:
  'The previous attempt failed to compile with these errors: <errors>. Fix the shader and produce a complete updated version.'
- If THAT also fails, give up and surface the errors to the user (current behavior).
- Cap at one retry to bound latency / token cost.

Notes:
- The GeneratePanel can show a small 'compiling…' / 'retrying with compiler feedback…' state.
- Multi-pass generation may need to compile each pass kernel separately to scope errors.
- Models that don't follow instructions well (small on-device model) may retry-loop without improving; the single-retry cap protects against that.

- `2026-06-18T23:38:57Z`: Implemented. ShaderGenerator.generate runs an automatic compile-on-success / retry-on-failure loop:

- After the model responds, parse the front-matter and run the body through PhosphorCompiler against MTLCreateSystemDefaultDevice().
- If compile throws, capture the error and call session.respond again with a follow-up prompt explaining the failure. (The session retains conversation history so the model already has its own attempt as context.)
- Single retry; second failure falls through to the runtime's diagnostics overlay as before.

Also along the way:
- GenerationPhase enum so the panel can show 'Generating…' / 'Compile failed, retrying with feedback…'.
- Empty-body responses are caught explicitly (ShaderGeneratorError.emptyBody).
- Decode failures from FoundationModels (the 'model omitted body' case) are translated to ShaderGeneratorError.malformedResponse.
- All model responses are logged to os.Logger (subsystem: io.schwa.PhosphorSupport, category: generator) so we can see what the model produced even when it's broken.
- The body field in GeneratedShader moved up to second position (right after title) and its @Guide description starts with 'Required. ... Always non-empty', which seems to help small models populate it.

---

## 31: Pause / play / reset / time-scrub controls

+++
status: closed
priority: medium
kind: none
created: 2026-06-18T23:01:19Z
updated: 2026-06-19T02:11:29Z
closed: 2026-06-19T02:11:29Z
+++

Add playback controls so the user can freeze a shader (and step through it) instead of having it always run at the drawable's refresh rate.

UI:
- Toolbar buttons: pause/play (toggle), reset, maybe a small time scrubber for paused mode.
- Possibly a transport bar at the bottom of the preview pane when paused.

Semantics:
- 'Pause' freezes `uniforms.time` and `uniforms.frame` at their current values; the runtime keeps rendering the same frame so the screen doesn't go dark.
- 'Play' resumes from where time was paused (NOT from t=0).
- 'Reset' sets time = 0 and frame = 0, and re-seeds the runtime's 'just-resized' flag so feedback shaders re-initialize.
- 'Step' (optional, while paused) advances one frame at a time. Useful for debugging ping-pong feedback.

Implementation sketch:
- Add a TimeController-ish struct in PhosphorView (or hoisted to PhosphorDocumentView) tracking: isPaused, accumulatedTime, currentFrame, lastWallClockSample.
- BuiltinUniforms construction uses TimeController's emitted values instead of reading frameUniforms.time/.index directly.
- Reset bumps a 'just-reset' signal that the runtime forwards to uniforms.resized (or a new uniforms.justReset field) so feedback shaders re-seed.
- Pause/play state persists per-document.

Related: #8 (resize re-seeding). Reset is essentially a manual trigger for the same code path.

Stretch:
- Record/playback time as a video.
- 'Slow motion' multiplier.
- 'Step back' is impossible without snapshotting feedback state \u2014 don't promise it.

- `2026-06-19T02:11:29Z`: Done. Three toolbar buttons: Pause/Play toggle (play.fill / pause.fill), Reset (arrow.counterclockwise). No scrub.

Semantics:
- Pause freezes uniforms->time and uniforms->frame at the values the kernel last saw. Captures the snapshot in PhosphorView's .onWorkloadEnter so it matches the renderer's clock exactly.
- Play resumes; kernel time picks up at the *current* wall-clock value (so paused duration adds to elapsed time — acceptable for shader playground use).
- Reset bumps a resetSignal, rebases timeBase/frameBase to whatever the renderer reports next frame, calls runtime.signalReset() which sets resizedFlag (so feedback shaders re-seed) and zeros all ping-pong textures. Reset also clears isPaused so the Play icon updates correctly.

PhosphorView gained isPaused: Binding<Bool>? and resetSignal: Int parameters (both optional / default-zero so existing call sites keep working). PhosphorRuntime gained signalReset() + zeroTexture(_:) helper.

---

## 32: Import Shader from Shadertoy URL or paste

+++
status: new
priority: low
kind: none
created: 2026-06-18T23:20:38Z
updated: 2026-06-18T23:22:39Z
+++

Add a File-menu command (and matching toolbar button?) that imports a Shadertoy shader into Phosphor, translating the GLSL to MSL on the way.

**Open question: how do we get the shader text?** I (Claude) initially claimed Shadertoy has a documented public API at `/api/v1/shaders/<id>` with an API-key system. I'm no longer confident any of that is real. Before designing anything, verify:

- Is there an official Shadertoy API at all?
- If yes, what's the endpoint shape and how does authentication work?
- If no, is there an alternative source for shader JSON / source (scraping the HTML page, an unofficial API, an existing third-party mirror, etc)?
- What does the rate limit / TOS allow for a desktop developer tool?

If a usable API exists, the import flow looks like:
1. User pastes a URL (or just a shader id).
2. Fetch the shader JSON.
3. Translate GLSL renderpasses to Phosphor passes (depends on #27, the GLSL→MSL compatibility layer).
4. Build a new Phosphor document with the result (once we have a clean New-from-X flow; deferred).

If no API exists, fall back to paste-only: user pastes the Shadertoy source into a text area, we run the same translator, document opens. Less convenient but unblocks the whole feature.

Either way, things to figure out:
- License + attribution. Shadertoy shaders are typically CC-BY-NC-SA-3.0 by default. Preserve the original author + URL as a header comment in the imported source.
- Multi-pass support. Shadertoy has Image / Buffer A-D / Common / Sound / Cubemap. Map each to a Phosphor pass with appropriate ping-pong config.
- iChannelN bindings. Shadertoy channels can be buffers, textures, cubemaps, video, audio, keyboard, microphone. For v1 only handle Buffer A-D and the 'no input' case; everything else turns into a TODO comment.

Related: #27 (Shadertoy compat layer), #26 (Shadertoy audit).

---

## 33: Audio input v1: signature change to device const Uniforms*

+++
status: closed
priority: low
kind: none
created: 2026-06-18T23:49:45Z
updated: 2026-06-19T00:08:16Z
closed: 2026-06-19T00:08:16Z
+++

Pre-requisite step for #17 (microphone input). Migrate kernel signatures from `constant Uniforms&` to `device const Uniforms*` so the Uniforms struct can carry device pointers (needed for audio buffers).

Scope:
- Update the synthesized PhosphorHeader Uniforms struct to expose two new `device const float*` pointers: `waveform` and `spectrum`. Initially they point at zero-filled MTLBuffers so kernels see zeros.
- Update the canonical kernel signature everywhere it's documented (system prompt, doc comments, README) from `constant Uniforms&` to `device const Uniforms*` and change every reference inside kernels from `uniforms.x` to `uniforms->x`.
- Update every shipped Examples/*.metal demo: Plasma, GameOfLife, Bloom, Accumulate, Noise, SolidColor, MouseProbe, ParityProbe.
- Update the generation schema instructions so the model produces the new signature.
- Verify all demos still render unchanged.

No audio capture yet \u2014 buffers stay zero-filled. This issue is purely the structural break so we can land audio safely afterwards.

Effort: small. ~30-45 min plus a couple build/test cycles.

- `2026-06-19T00:08:16Z`: Done. Migrated kernels from `constant Uniforms&` to `device const Uniforms*` so the Uniforms struct can carry device pointers.
- `2026-06-19T00:08:16Z`: BuiltinUniforms gains two UInt64 fields (waveform, spectrum) holding GPU addresses. Struct grows from 48 to 64 bytes; layout test updated.
- `2026-06-19T00:08:16Z`: PhosphorRuntime allocates zero-filled waveformBuffer (1024 floats) and spectrumBuffer (512 floats) at init. writeBuiltinUniforms writes their gpuAddress into the uniforms struct each frame.
- `2026-06-19T00:08:16Z`: PhosphorPipeline calls useResource on both audio buffers in the compute encoder so they're resident when the kernel dereferences them via the Uniforms argument buffer.
- `2026-06-19T00:08:16Z`: PhosphorHeader.uniformsDecl() now emits two `device const float*` fields in the synthesized Uniforms MSL struct.
- `2026-06-19T00:08:16Z`: All 8 Examples/*.metal demos and CompileTests embedded sources updated: signature switch + every uniforms.x → uniforms->x.
- `2026-06-19T00:08:16Z`: ShaderGenerator system prompt and all 3 worked examples updated to the new signature.
- `2026-06-19T00:08:16Z`: All 39 tests pass; existing demos render unchanged.

---

## 34: Audio input v2: AVAudioEngine capture pipeline

+++
status: closed
priority: low
kind: none
created: 2026-06-18T23:49:57Z
updated: 2026-06-19T00:24:56Z
closed: 2026-06-19T00:24:56Z
+++

Capture step for #17. Depends on #33 (signature change landed first).

Scope:
- Add an `AudioCaptureEngine` (or similar) in PhosphorSupport that owns:
  - An AVAudioEngine instance with a tap on the input node.
  - A small lock-protected ring buffer of the most recent ~1024 mono Float32 samples.
- Settings UI: a 'Microphone' toggle in SettingsView. When OFF, the engine is stopped and the ring buffer stays zero. When ON, prompt for the entitlement on first use; if denied, fall back to OFF.
- Plumb a 'mic enabled' AppStorage key through PhosphorView -> PhosphorRuntime so the runtime knows whether to populate the audio buffers each frame.
- Info.plist: add NSMicrophoneUsageDescription and the audio-input entitlement (com.apple.security.device.audio-input on macOS sandbox).
- Hook AVAudioSession-style routing on macOS (it differs from iOS; check the AVFoundation docs).

Output: `audioWaveformBuffer` on PhosphorRuntime is populated each frame with the most recent 1024 samples (centered around 0.5 if we follow Shadertoy, or raw -1..1 \u2014 decide which).

No FFT yet \u2014 spectrum buffer stays zero. That's the next issue.

Effort: medium. AVAudioEngine + sandboxed permissions are the main complications.

- `2026-06-19T00:24:56Z`: Done. AudioCaptureEngine in PhosphorSupport wraps AVAudioEngine with a tap on the input node, populates a 1024-sample mono Float32 ring buffer with the most recent audio, and exposes copyLatestSamples(into:) for the render loop.

@Observable, @MainActor for control surface; lock-protected nonisolated ring buffer + isRunning flag so the Metal render loop can read without bouncing through the actor. Injected via SwiftUI environment (\.audioCapture).

App-side: PhosphorApp creates and owns the engine, persists isEnabled via @AppStorage. PhosphorDocumentView's toolbar gains a mic toggle (mic.fill / mic.slash) bound to the same AppStorage key; disabled with help text when permission was denied.

PhosphorRuntime gains writeAudioBuffers() which is called by PhosphorPipeline each frame. When the engine is running it copies the ring buffer into waveformBuffer; otherwise zero-fills. The spectrum buffer remains zero until #35 (FFT).

Note: permission-prompt plumbing through the sandbox audio-input entitlement is incomplete; works when the entitlement is already present, falls through gracefully when missing.

---

## 35: Audio input v3: FFT for spectrum buffer

+++
status: closed
priority: low
kind: none
created: 2026-06-18T23:50:07Z
updated: 2026-06-19T00:52:51Z
closed: 2026-06-19T00:52:51Z
+++

FFT step for #17. Depends on #34 (capture pipeline landed).

Scope:
- Use vDSP_DFT_zop_CreateSetup (or vDSP_FFT_zip / vDSP.DFT) to forward-transform the most recent 1024 waveform samples.
- Compute linear magnitudes (sqrt(re^2 + im^2)), normalize to 0..1, write into the `audioSpectrumBuffer` (512 bins).
- Apply a window function (Hann is the standard choice) before the FFT to reduce spectral leakage.
- Optional: smooth across frames so the spectrum doesn't strobe \u2014 weighted average with the previous frame's magnitudes.

Output: `audioSpectrumBuffer` on PhosphorRuntime is populated each frame.

Tests:
- A 1 kHz sine into the mic should produce a clear peak at the corresponding FFT bin.
- An audio probe demo (#35 below) visualises both buffers so we can sanity-check.

Effort: medium. vDSP API surface is fiddly, especially the setup/teardown and the interleaved real/imaginary buffer layouts.

- `2026-06-19T00:52:51Z`: Done. SpectrumAnalyzer (Accelerate framework) wraps vDSP.FFT for forward 1024-point real FFT with a Hann window, linear-magnitude normalization to ~[0,1], and cross-frame smoothing (default α=0.4) so the spectrum doesn't strobe.

PhosphorRuntime.writeAudioBuffers() lazily creates the analyzer and processes the waveform into spectrumBuffer every frame. Zero-fills when the capture engine isn't running.

---

## 36: Audio input v4: AudioProbe.metal demo + docs

+++
status: closed
priority: low
kind: none
created: 2026-06-18T23:50:19Z
updated: 2026-06-19T00:52:51Z
closed: 2026-06-19T00:52:51Z
+++

Final step for #17. Depends on #33 (signature change), #34 (capture), and #35 (FFT).

Scope:
- Examples/AudioProbe.metal: a single-pass shader that draws the waveform as a horizontal line across the middle of the screen and the FFT magnitudes as vertical bars below, classic oscilloscope + spectrum-analyzer layout. Tests both buffers visually.
- Update the README and the generation system prompt to mention the new uniforms.waveform and uniforms.spectrum pointers (size 1024 and 512 respectively, Float, available always but zero when the mic is off).
- Update the Phosphor.h synthesized header documentation comment so the popover surfaces what the new fields are.

Tests:
- Whistle into the mic \u2014 should see a peak at the corresponding bin in the spectrum bar visualisation.
- Speak / hum \u2014 waveform line wiggles.
- Toggle mic off in Settings \u2014 visualisation flatlines.

Effort: small. ~30 min. Closes #17 once landed.

- `2026-06-19T00:52:51Z`: Done. Examples/AudioProbe.metal: top half is an oscilloscope (1024-sample waveform as a green glowing trace), bottom half is a spectrum analyzer (512 FFT bins as bars colored blue at low freq, red at high). Mid-line separator. System prompt updated to document uniforms->waveform and uniforms->spectrum with their sizes and value ranges.

Audio buffers verified end to end: mic toggle enables capture; AudioProbe shows live waveform + spectrum.

---

## 37: System audio input via ScreenCaptureKit

+++
status: new
priority: low
kind: none
created: 2026-06-19T00:59:05Z
+++

Today, audio input is mic only via AVAudioEngine (#17). Add system audio (what's playing through the speakers) as a second source so users can drive shaders from their music.

Use `ScreenCaptureKit` (macOS 13+):
- `SCContentFilter` configured for `.displayExcludingApplications` or similar; we only want audio, no video.
- `SCStream` with `.audio` capture type. The video output is irrelevant; we discard it (or use the smallest possible capture region).
- `SCStreamConfiguration.capturesAudio = true`, `channelCount = 1` (mono mixdown).
- Receive `CMSampleBuffer`s via SCStreamOutput; pull PCM frames and feed them into the same ring buffer used by AVAudioEngine.

Implementation:
- Refactor AudioCaptureEngine to abstract its source. A new `SystemAudioCaptureSource` (or similar) wraps SCStream and writes into the same AudioRingStorage; AudioCaptureEngine picks between mic and system based on a setting.
- Settings UI: source picker (Microphone / System Audio / Off). Persisted via @AppStorage.
- Toolbar mic toggle stays; its meaning becomes 'enable audio capture from the currently-selected source'.

Permissions / entitlements:
- ScreenCaptureKit requires the screen-recording permission. Phosphor will need TCC ScreenRecording. Add to entitlements + Info.plist with a clear usage description explaining we only want audio.
- First use prompts the user. Denied -> falls back to Off, surfaced in the toolbar.

Why not other options:
- Loopback audio drivers (BlackHole, Loopback.app) require the user to install a kext / system extension. High friction.
- CoreAudio process tap (macOS 14.4+, AudioHardwareCreateProcessTap) is a newer alternative without the screen-recording prompt, but more code and less Swift-native. Worth revisiting if the screen-recording prompt is confusing for users.

Related: #17 (mic input).

---

## 38: TOML generation is verbose; try to make tomlkit produce a more compact output

+++
status: closed
priority: low
kind: enhancement
created: 2026-06-19T01:04:30Z
updated: 2026-06-19T17:06:14Z
closed: 2026-06-19T17:06:14Z
+++

Current TOML generation produces rather verbose output. Investigate ways to coax tomlkit into emitting a more compact representation (e.g. inline tables, inline arrays, fewer blank lines, compact dict styling) where appropriate.

- `2026-06-19T02:24:56Z`: Partial progress: applied the two trivial TOMLKit FormatOptions tweaks:

- Dropped `.allowLiteralStrings` so strings emit as double-quoted (`"image"` vs `'image'`), matching the hand-written Examples.
- Added `.relaxedFloatPrecision` so 0.6 doesn't serialize as 0.60000002384185791.

What's still verbose: TOMLKit always expands sub-tables into `[parent.child]` sections instead of inline tables. Hand-written examples use:

    spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }
    ui = { slider = { min = 0.5, max = 24.0 } }

The generator still emits:

    [resources.spec]
    flipTiming = 'endOfFrame'
    format = 'rgba32Float'
    ...

This is controlled by the toml++ C++ writer below TOMLKit and is NOT exposed via FormatOptions. Fixing it requires either:

1. A post-encode walk of the `TOMLTable` that sets `.inline = true` on every leaf sub-table (TOMLKit exposes this property). ~30-50 lines.
2. Our own bespoke encoder for `PhosphorEnvironment` that produces the desired layout directly.

Leaving open for option 1 or 2 later.

- `2026-06-19T02:32:58Z`: Closed via partial fix. Inline-tables-for-leaf-records would need our own encoding (TOMLKit always splits sub-tables into [parent.child] sections; not configurable via FormatOptions). Will revisit if it becomes a problem in practice.
- `2026-06-19T17:06:14Z`: Done. FrontMatterFormatter now post-processes TOMLKit's encoded TOMLTable and flags deep sub-tables as inline, so output matches the hand-written Examples style (sectional [[resources]], inline spec = { ... }). Also wired up Edit > Reformat Front Matter to apply the same encoder to the active document.

---

## 39: Video input: webcam source

+++
status: open
priority: medium
kind: feature
created: 2026-06-19T01:23:57Z
updated: 2026-06-19T16:16:03Z
+++

Add support for using a webcam as a live video input source.

---

## 40: Architecture: deepen render orchestrator (Runtime + Pipeline)

+++
status: new
priority: medium
kind: enhancement
labels: architecture
created: 2026-06-19T02:15:39Z
+++

## Problem

`PhosphorRuntime` (507 LOC, `@Observable` class) and `PhosphorPipeline` (116 LOC, MetalSprockets Element) are tightly coupled but neither owns the abstraction. Runtime exposes ~8 distinct mutating methods (`ensureTextures`, `writeAudioBuffers`, `writeBuiltinUniforms`, `writeUserUniforms`, `writeChannelBuffers(parity:)`, `signalReset`, plus per-pass lookups). Pipeline's `body` is a 5-line cheat sheet that calls them in the exact right order, computes parity, and decides what each `iChannelN` binds to.

The real coordination logic — ping-pong parity, cross-pass write/read tracking inside `writeChannelBuffers`, the reset "resized" flag, the per-frame buffer-realloc dance — is split across both files. There's no single place that owns the per-frame protocol; getting it wrong silently produces visual bugs that no test catches.

Symptoms:

- Pipeline mutates Runtime state (channel buffers) via a method that ALSO returns useLists. Two-tier protocol.
- Pause/reset state (issue #31) lives in PhosphorView, communicating with Runtime via `signalReset()` AND with the frame closure via private `@State`. Three actors on one timeline.
- The 26-shader render-smoke suite is the only thing that catches per-frame protocol regressions, and it doesn't probe parity, reset semantics, or the upstream-write-this-frame rule.

## Proposed Direction

Merge into a single deep `PhosphorRenderer` module. Inputs: an environment, a source string, and a per-frame inputs struct (time, frame, mouse, drawable size, paused-or-not, reset-this-frame). Output: an Element that renders this frame. Hide: texture allocation, parity bookkeeping, channel-buffer assembly, uniforms packing, audio buffer plumbing, the fallback texture, the reset flag.

Callers (currently `PhosphorView`) should only need to construct one struct and emit one Element per frame. No `@Observable` Runtime to thread through views; no separate `Pipeline` element to remember the call order.

## Dependency Category

In-process. `MTLDevice` and the user's `AudioCaptureEngine` are the only externals; both are already injected.

## Testing Strategy

- **New boundary tests**: extend render-smoke harness to assert specific behaviors — Game of Life reseeds when `resized` fires; multi-pass shaders see same-frame writes from upstream passes; paused frame produces byte-identical output to the prior frame; reset zeros ping-pong contents.
- **Old tests to delete**: none currently exist for Runtime/Pipeline internals (the smoke suite is already the boundary).

## Files Involved

- `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PhosphorRuntime.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PhosphorPipeline.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PingPongTexture.swift`
- Parts of `Packages/PhosphorSupport/Sources/PhosphorSupport/UI/PhosphorView.swift` (playback wiring)

---

## 41: Architecture: deepen shader compile pipeline

+++
status: closed
priority: medium
kind: enhancement
labels: architecture
created: 2026-06-19T02:15:58Z
updated: 2026-06-21T06:04:34Z
closed: 2026-06-21T06:04:34Z
+++

## Problem

Three callers all do the same 6-step dance to compile a Phosphor source string into an `MTLLibrary` with per-pass functions:

1. `PhosphorRuntime.recompile` — calls `validate` + `PhosphorCompiler.compileLibrary` + `makeFunction` per pass.
2. `ShaderGenerator.tryCompile` — reproduces the same dance to check whether generated source compiles, for retry-on-error.
3. `SourceAssembler.assemble` is called inside the compiler but is also conceptually part of the chain.

Each step is its own module:

- `SourceAssembler` (38 LOC): strips include + front-matter, prepends prelude.
- `PhosphorHeader` (281 LOC): builds prelude string.
- `PhosphorCompiler` (47 LOC): `makeLibrary` + `makeFunction`.
- `Validation` (101 LOC): structural diagnostics.

No public function takes a source string and returns "library + functions + diagnostics". Every caller stitches its own.

## Proposed Direction

A single deep `ShaderCompilePipeline` (name TBD) with one entry point:

```swift
public func compile(source: String, device: MTLDevice) throws -> CompiledShader
```

where `CompiledShader` carries the parsed environment, the library, the per-pass MTLFunctions, and any non-fatal diagnostics. Internally it does parse → validate → assemble → `makeLibrary` → `makeFunction` per pass, with a single `CompileError` enum for the things that can go wrong.

`SourceAssembler` and `PhosphorCompiler` become internal helpers (or get inlined). `PhosphorHeader` stays public because the UI displays it.

## Dependency Category

In-process. Pure transformation + `MTLDevice`.

## Testing Strategy

- **New boundary tests**: "given source X, I get library Y with functions Z" or specific diagnostic D. One test per category instead of one per internal module.
- **Old tests to consolidate**: `SourceAssemblerTests`, parts of `CompileTests`, parts of `FrontMatterTests` (the ones that test what the runtime would see).
- **Old tests to keep**: `PhosphorHeader` structural tests (the header is its own public surface for the UI).

## Files Involved

- `Packages/PhosphorSupport/Sources/PhosphorSupport/Compile/PhosphorCompiler.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Source/SourceAssembler.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Source/PhosphorHeader.swift` (keep public)
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Parser/FrontMatter.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Model/Validation.swift`
- Callers in Runtime + ShaderGenerator

---

## 42: Architecture: collapse document parse + validate to single path

+++
status: closed
priority: low
kind: enhancement
labels: architecture
created: 2026-06-19T02:16:14Z
updated: 2026-06-21T06:08:42Z
closed: 2026-06-21T06:08:42Z
+++

## Problem

Validation runs three times for one document:

1. `PhosphorFrontMatter.parse` calls `validate` and stuffs the diagnostics into `ParsedPhosphorSource.diagnostics`.
2. `PhosphorRuntime.recompile` (called from `init` and `update`) calls `validate` again on the same environment.
3. `ShaderGenerator` converts `GeneratedShader` to env via `toPhosphorEnvironment`, which calls `validate` a third time, then the runtime calls it again on the rendered source.

This is mostly redundancy rather than coupling, but the seam between `ParsedPhosphorSource` and the rest of the codebase is fuzzy: it carries diagnostics, but downstream consumers re-derive them anyway because they don't trust the input.

## Proposed Direction

Make `ParsedPhosphorSource` (or its successor) authoritative. Runtime trusts the parse step; validation runs once. The Document layer holds the parsed view (already does, via `PhosphorMetalDocument.parsed`). Runtime accepts `ParsedPhosphorSource`, not raw source + environment.

This pairs with #41 (compile pipeline) — that issue could already take a `ParsedPhosphorSource` as input.

## Dependency Category

In-process. Pure value plumbing.

## Testing Strategy

- **New boundary tests**: none new really; existing FrontMatter + Validation tests cover the parse path. Mostly a removal of duplicate `validate()` calls.
- **Net change**: smaller blast radius for environment changes, less re-work per document update.

## Files Involved

- `Packages/PhosphorSupport/Sources/PhosphorSupport/Parser/FrontMatter.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Model/Validation.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PhosphorRuntime.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Generation/GeneratedShader.swift`

---

## 43: Architecture: extract playback clock as deep module

+++
status: closed
priority: low
kind: enhancement
labels: architecture
created: 2026-06-19T02:16:32Z
updated: 2026-06-21T05:59:12Z
closed: 2026-06-21T05:59:12Z
+++

## Problem

Pause/play/reset logic (issue #31, just landed) is implemented as five `@State` properties + two helpers + one Runtime method, all scattered across `PhosphorView`:

- `timeBase: Float`, `frameBase: UInt32`
- `pausedSnapshot: (time, frame)?`
- `capturePauseSnapshot: Bool` (sentinel for capture-on-next-frame)
- `rebaseRequested: Bool` (sentinel for rebase-on-next-frame)
- `buildUniforms(context:drawableSize:)`
- `applyPlaybackSideEffects(context:)` (runs from `.onWorkloadEnter`)
- `PhosphorRuntime.signalReset()` + `resizedFlag`

The logic is tricky (had three failed attempts during implementation) and only quasi-tested via render-smoke. The interaction with MetalSprockets' element-builder rules (mutations can't happen inside `@ElementBuilder` closures) forced a deferred-snapshot dance that's hard to read.

## Proposed Direction

Extract a value-type `PlaybackClock` (struct or small `@Observable`):

```swift
struct PlaybackClock {
    mutating func tick(wallClockTime: Float, wallClockFrame: UInt32) -> (time: Float, frame: Float)
    mutating func pause()
    mutating func resume()
    mutating func reset() -> Bool   // returns true if reset fired this tick
}
```

PhosphorView holds one of these in `@State` and feeds it the renderer's clock each frame; gets back kernel time/frame. The runtime's `resizedFlag` becomes the `reset() -> Bool` return value, plumbed through the inputs struct.

## Dependency Category

In-process. Pure state machine.

## Testing Strategy

- **New boundary tests**: "given (wall_time, events) sequence, assert (kernel_time, kernel_frame, reset) sequence." Fully unit-testable, no Metal needed.
- **Old tests to delete**: none — this logic is currently untested at the unit level.
- Pause/resume semantics and the "reset clears pause" rule become assertion-level rather than 'try it and see'.

## Files Involved

- `Packages/PhosphorSupport/Sources/PhosphorSupport/UI/PhosphorView.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PhosphorRuntime.swift` (resizedFlag, signalReset)

---

## 44: Architecture: deepen shader generation pipeline (ports & adapters)

+++
status: closed
priority: medium
kind: enhancement
labels: architecture
created: 2026-06-19T02:16:51Z
updated: 2026-06-22T03:48:15Z
closed: 2026-06-22T03:48:15Z
+++

## Problem

`ShaderGenerator` (457 LOC) is a single struct with one `generate` method that does ~7 things, plus a 250-line instructions constant. Backend selection (on-device / PCC / Anthropic), prompt assembly, response decoding, env conversion, compile check, retry loop with error feedback — all stitched together by static helpers. The compile-check step duplicates the compile path PhosphorRuntime takes (see #41).

Currently untested. Zero generator tests exist, partly because:

- It directly depends on `FoundationModels` (`LanguageModelSession`, `SystemLanguageModel`).
- It directly depends on `FoundationModelBackends.AnthropicLanguageModel` (real HTTP).
- It reads from Keychain.

These dependencies are hard-coded into `makeSession`, so a test can't substitute a fake.

## Proposed Direction (Ports & Adapters)

Define a `LanguageModelPort` protocol the generator depends on:

```swift
protocol LanguageModelPort {
    func respond<T: Generable>(prompt: String, generating type: T.Type) async throws -> T
}
```

Production adapters: `OnDeviceAdapter`, `PCCAdapter`, `AnthropicAdapter` (this last one carries the API key). The Generate panel constructs the right adapter from `GenerationModel` + Keychain.

Test adapter: `FakeLanguageModel` that returns scripted responses. Lets us test:

- Retry-on-compile-error fires when first response doesn't compile.
- Empty body throws `emptyBody`.
- Prompt assembly for modify-existing.
- Prompt history is preserved.

The 250-line instructions constant moves to its own file (or a generated resource). The compile-check step uses the deepened compile pipeline from #41.

## Dependency Category

- **Language model backends**: True external (Anthropic) and local-substitutable (FoundationModels). Both move behind a port.
- **Keychain**: Local-substitutable. Inject the API key string, not the Keychain lookup.

## Testing Strategy

- **New boundary tests**: full retry-loop, prompt assembly, env conversion edge cases. Using a fake adapter, no network or Apple Intelligence required.
- **Old tests to delete**: none exist.
- **Test environment needs**: `FakeLanguageModel` in the test target.

## Files Involved

- `Packages/PhosphorSupport/Sources/PhosphorSupport/Generation/ShaderGenerator.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Generation/GeneratedShader.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Generation/KeychainStore.swift`
- `Packages/PhosphorSupport/Sources/PhosphorSupport/Generation/PromptHistory.swift`
- `Phosphor/GeneratePanel.swift` (constructs the adapter)

---

## 45: SwiftUI: restructure PhosphorView body composition

+++
status: closed
priority: low
kind: enhancement
labels: swiftui, architecture
created: 2026-06-19T02:32:17Z
updated: 2026-06-20T19:35:58Z
closed: 2026-06-20T19:35:58Z
+++

## Problem

`PhosphorView.body` is a single `ZStack` containing an `if let runtime / else if let initError / else` branch chain. The success branch alone is 70+ lines: a `RenderView` with chained modifiers `.onGeometryChange`, two `.onChange` (pause + reset), `.onContinuousHover`, a `DragGesture`, and two `.overlay`s.

Per the house rules (`references/structure.md`), each conditional branch should be its own `View` struct. The overlays were extracted already (#46 work); the three-branch body and the success-branch composition are still inline.

## Proposed

Split the body into:
- `PhosphorRunningView` (success branch \u2014 owns the RenderView + gestures + overlays)
- `PhosphorErrorView` (already exists)
- `PhosphorLoadingView` (current `Color.black` placeholder)

The dispatch in `body` becomes a short switch / if-let chain that picks one of the three.

## Out of scope

The playback clock state machine inside the running view stays where it is for now; #43 tracks extracting that as a separate value type.

## Files

- `2026-06-19T02:32:17Z`: `Packages/PhosphorSupport/Sources/PhosphorSupport/UI/PhosphorView.swift`
- `2026-06-20T19:35:58Z`: Done in audit pass. PhosphorView.body collapses to a dispatch between PhosphorRunningView and PhosphorLoadingView. The running view owns its own playback + input @State and the RenderView setup. PhosphorErrorView already existed but is unused after the runtime moved into PhosphorRuntimeStore; it can be deleted in a follow-up cleanup.

---

## 46: .phosphor bundle document format (file package with embedded assets)

+++
status: closed
priority: medium
kind: feature
labels: architecture
created: 2026-06-19T02:46:40Z
updated: 2026-06-19T17:07:02Z
closed: 2026-06-19T17:07:02Z
+++

## Why

Currently the only document type is plain `.metal` (UTF-8 text). That's fine
for procedural / audio-reactive / feedback shaders, but blocks anything that
needs a static input texture (image-process effects, dither LUTs, font atlases,
reaction-diffusion seeds). Sandboxing makes naive `file://` URLs in TOML
front-matter unworkable: the URL is unreachable on next launch unless the user
re-grants permission via security-scoped bookmarks (awful UX).

Pattern: a file package (a directory presented as a single file in Finder),
same as `.pages`, `.key`, or an Xcode project. The sandboxed app reads
and writes its contents freely.

## Scope (v1)

- Two document types side by side:
  - `.metal` (existing, unchanged) for lightweight single-file shaders.
  - `.phosphor` (new) for shaders that need bundled assets.
- v1 `.phosphor` holds exactly **one** active `.metal` shader plus its
  assets. Multi-shader picker comes later (see Future).
- Bundle layout (proposed, not final):
    .phosphor/
      shader.metal      # the active source
      assets/
        foo.png
        noise.jpg
      info.json         # optional manifest (e.g. selected shader id once we go multi)
- Asset names in front-matter (`initial = "image"`, `name = "foo"`) resolve
  against `assets/`.
- Drag/drop or paste an image -> auto-migrate the open `.metal` doc to a
  `.phosphor` bundle ("Save as Phosphor Bundle\u2026" if auto isn't feasible
  through SwiftUI document APIs).
- `.metal` and `.phosphor` share parse / runtime / generation paths. The
  bundle wrapper is mostly an asset-resolution + persistence concern.

## Out of scope (v1)

- Multiple `.metal` files inside one `.phosphor` (deferred to v2, see
  Future).
- Co-rendering multiple shaders (likely never \u2014 multi-pass already handles
  cross-pass sampling within one file).

## Future / v2+

- Multiple `.metal` files in one bundle + a shader picker UI.
- Embedded sample audio.
- Embedded fonts / atlases for text effects.

## Implementation notes

- Use SwiftUI's `PackageDocument` / `FileWrapper`-based document types
  (the SDK 27 ReadableDocument/WritableDocument API supports both flat and
  package representations).
- UTType for the bundle: `com.schwa.phosphor.bundle`, conforming to
  `com.apple.package`.
- The auto-migrate-on-image-drop step needs investigation; SwiftUI's
  document-based-app API may force a Save dialog (file extension change).
  If unavoidable, fall back to an explicit menu item.

## Blocks

#1 (image asset loading), #11 (texture picker UI), #26 / #27 (Shadertoy
compatibility \u2014 channel images), #39 (webcam input, same materialization
path).

- `2026-06-19T17:07:02Z`: v1 scope landed. Both doc types ship, .phosphord bundles persist shader.metal + assets/, asset name resolution works end-to-end, both doc types share the editor body and runtime via plain bindings.

The 'auto-migrate .metal to .phosphord on image drop' UX item is not done. Plain .metal documents handle text fine; users who want assets create a new Phosphor Bundle. We'll file migration as a separate issue if it comes up.

---

## 47: Add gain control to microphone input

+++
status: closed
priority: medium
kind: enhancement
created: 2026-06-19T03:10:45Z
updated: 2026-06-19T16:08:48Z
closed: 2026-06-19T16:08:48Z
+++

Add an adjustable gain control to the microphone input so users can boost or attenuate the input level.

- `2026-06-19T16:08:48Z`: Closing: shaders that need scaled audio can declare a 'gain' user uniform and multiply it into uniforms->waveform[i] / spectrum[i] themselves. No app-level control needed.

---

## 48: Generator: send a rendered-frame screenshot back into the generator for visual feedback

+++
status: new
priority: medium
kind: feature
labels: generation
created: 2026-06-19T03:25:39Z
+++

## Problem

Today the generator is text-only: prompt in, source out, plus a one-shot retry
if the compile fails. There's no signal about how the output *looks* once it
renders. If the user prompts for a 'fiery red glow' and gets a green one, the
only fix is to try again with a more detailed prompt.

## Idea

Capture the current rendered frame from the live preview, attach it (alongside
the prompt + existing source) to the next generation request. Multi-modal
backends (Claude vision; potentially PCC) can then steer the shader toward
what's on screen.

## v1 scope (proposed)

- Generate panel grows a 'Use current frame' checkbox.
- When checked, the panel pulls a PNG snapshot from the live PhosphorView (via
  the existing MetalSprockets render pipeline or a one-shot offscreen
  rasterize) and attaches it to the LanguageModelSession request.
- Anthropic backend: send via the existing vision content type. On-device /
  PCC: gate the checkbox off (or surface a 'not supported on this model'
  hint).
- Treat the image as a *complement* to the existing prompt, not a replacement
  \u2014 the prompt still drives intent.

## Out of scope (later)

- Multiple-frame storyboards.
- Annotating the screenshot (arrows, masks).
- Generator-initiated 'render N frames and diff against a target image'
  iteration loops.

## Open design questions

- How big should the screenshot be? Models charge by image tokens; 512\u00d7512
  is probably the sweet spot. The live preview is whatever the window is.
- Does the screenshot bypass or include the front-matter? Sending just the
  pixels gives the model less to anchor on; sending source+frame ties them
  together but eats more tokens.
- Reuse the existing pause/reset mechanism to ensure a stable capture, or
  capture during normal playback?

## Related

- Depends on multi-modal support in the FoundationModelBackends adapter
  layer we use for Anthropic.
- Pairs naturally with #44 (deepen the generation pipeline / ports & adapters)
  \u2014 the screenshot becomes another input on the LanguageModelPort.

---

## 49: Rename .phosphor bundle extension to .phosphord

+++
status: closed
priority: low
kind: task
created: 2026-06-19T16:08:19Z
updated: 2026-06-19T16:10:31Z
closed: 2026-06-19T16:10:31Z
+++

Rename the bundle file extension from `.phosphor` to `.phosphord`. The
trailing 'd' disambiguates from anything Phosphor-the-brand might want for
a different format later, and matches the document-suffix pattern (`.keyd`,
`.numberd`-style conventions don't exist but the extra letter still reads
'document').

## Touch points

- `UTType.phosphorBundle` (exported identifier stays
  `io.schwa.phosphor.bundle`; the user-facing extension is what changes)
- `Info.plist`:
  - `UTExportedTypeDeclarations[0].UTTypeTagSpecification.public.filename-extension`
- `Phosphor/PhosphorBundleDocument.swift`: any hard-coded references
  (none today, since the extension is plist-driven, but worth a grep)
- Any existing `.phosphor` files on disk would need to be renamed by hand;
  in-development only, so no migration code needed.

## Out of scope

- `2026-06-19T16:08:19Z`: Migrating already-shipped bundles. Pre-rename builds aren't released.
- `2026-06-19T16:10:31Z`: Done. UTI string stays io.schwa.phosphor.bundle; Swift symbol stays UTType.phosphorBundle. Only the user-facing extension flips to .phosphord. The flat-file .phosphor format will land in a future change.

---

## 50: Texture model redesign: named bindings, action-based init, unified outputs/inputs

+++
status: closed
priority: medium
kind: feature
labels: architecture
created: 2026-06-19T16:43:18Z
updated: 2026-06-19T18:10:25Z
closed: 2026-06-19T18:10:25Z
+++

## Problem

The current texture model carries three layers of accumulated cruft that
should be redesigned together:

### 1. Bindings are inconsistent

Inputs go into auto-generated `iChannel0` \u2026 `iChannel3` slots on a
`ChannelBindings` struct (Shadertoy holdover). Outputs are a special
`outTexture [[texture(0)]]` parameter, separate from everything else.
The naming inside the kernel (`channels.iChannel0`) doesn't match what
the resource is, and the in-kernel API distinguishes 'output' and 'input'
when in reality both are just textures with different access modes.

### 2. Resources have two shapes

`Resource.texture2D(id, spec)` and `Resource.image(id, name, access)`.
The `.image` shape was added to skip pre-declaring size and format for
image-backed textures \u2014 but that's not a different kind of resource,
it's a texture seeded by a particular init action.

### 3. Init and ping-pong are encoded as fields, not actions

`spec.initial = .image(name) | .zero | .color(...) | .noise(...)` is
mostly TODO; only `.zero` and `.image` work. `spec.pingPong: Bool` +
`spec.flipTiming: .endOfFrame | .immediate` encode 'when does the swap
happen' as two coupled fields. Three different mechanisms for what is
really one concept ('how does this texture behave at init / mid-frame /
end of frame').

## Goal

One consistent texture model:

- A resource is always a 2D texture.
- It has user-named bindings per pass; each binding has its own access
  mode (`read` / `sample` / `write` / `read_write`).
- Init is an action with kinds (`zero`, `image`, `color`, `noise`),
  each with its own parameters.
- Swap timing is one field (`none` / `endOfFrame` / `immediate`), not
  a Bool plus a separate timing enum.
- Size and format default sensibly; image-backed textures derive them
  from the decoded asset.

## Proposed shape

```toml
# Procedural single-pass: full defaults.
[[textures]]
id = "image"

# Image-backed texture: size + format derived from the asset.
[[textures]]
id = "photo"
init = { kind = "image", name = "screenshot" }

# Feedback buffer with explicit swap timing.
[[textures]]
id = "trail"
swap = "endOfFrame"   # or "none" (default) or "immediate"

[[passes]]
id = "image"
textures = [
    { name = "output",   resource = "image", access = "write"  },
    { name = "photo",    resource = "photo", access = "sample" },
    { name = "history",  resource = "trail", access = "read"   },
]
```

Kernel:

```metal
kernel void image(
    device const Textures&     textures     [[buffer(1)]],
    device const Uniforms*     uniforms     [[buffer(0)]],
    device const UserUniforms* userUniforms [[buffer(2)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    constexpr sampler s(mag_filter::linear);
    float4 c = textures.photo.sample(s, uv);
    textures.output.write(c, gid);
}
```

## Implementation notes

- Single `Resource.texture2D` (or rename to `.texture`). Drop `.image`
  case entirely.
- `TextureInit` becomes a fully-modeled enum with payloads, all kinds
  actually implemented.
- `SwapTiming` (`none` / `endOfFrame` / `immediate`) replaces
  `pingPong: Bool` + `flipTiming`.
- Bindings are named on each pass; access mode per binding.
- `PhosphorHeader` emits a `Textures` struct (name TBD) with one field
  per named binding, with the matching MSL access qualifier.
- `outTexture [[texture(0)]]` special parameter goes away; pass writes
  through whichever binding has `access = "write"` or `"read_write"`.
- Runtime's `writeChannelBuffers` becomes per-binding-name rather than
  per-numeric-slot.
- Top-level env `output = "image"` stays \u2014 tells the preview which
  resource to blit. Distinct from per-pass outputs.

## Decisions to make during impl

- Final struct name: `Textures` (matches reality), `Bindings`, or
  `Channels` (keep the Shadertoy nod)?
- Path syntax: `textures.output` flat, or namespaced like
  `channels.images.output`? Probably flat; revisit if buffers / samplers
  become first-class bindings.
- Init action re-triggerability: could conceivably be a runtime action
  the user fires from the toolbar (so 'reseed Game of Life' becomes
  'rerun the init action'). Out of scope for v1 but the shape leaves
  room.

## Breaking changes

**Every example shader has to be ported.** ~35 `.metal` files in
`Examples/`. Changes are mostly mechanical:

- Replace `iChannel0` / `channels.iChannelN` references with the named
  binding from the pass's `textures = [\u2026]` list.
- Drop the `outTexture [[texture(0)]]` kernel parameter, write through
  the named output binding instead.
- Convert `spec.pingPong = true` -> `swap = "endOfFrame"`.
- Convert `initial = "image", name = \u2026` -> `init = { kind = "image",
  name = \u2026 }`.

Also update generator instructions and the new-document templates.

## Out of scope

- Sampler objects as first-class bindings.
- Buffer resources alongside textures.
- True simultaneous `access::read_write` on compute outputs.

## Supersedes

- #52 (resources-are-textures redesign) \u2014 same scope, folded in here.

## Related

- #1, #50 history: assets and the `.image` resource case were the cracks
  that motivated this redesign.
- #48 (screenshot-to-generator) makes texture bindings more central.
- #51 (sensible defaults) is downstream \u2014 with this model, defaults
  become easy to express.

- `2026-06-19T18:10:25Z`: Done. Texture model redesign landed across 6 commits, RFC at RFCs/RFC-001-texture-model-redesign.md.

Summary:
- Resource enum -> flat Texture value type with id/size/format/swap/init.
- TextureInit cases: zero / fill(rgba) / image(file) / noise(seed).
- SwapTiming: none / endOfFrame / immediate (immediate still unimplemented, #4).
- TextureAccess gains write + readWrite.
- Pass.TextureBinding(id, access, name?) — id IS the binding name unless overridden via name (needed for self-feedback with separate read + write bindings on a swap texture).
- PhosphorHeader emits per-pass Pass_<id>_Uniforms struct containing scalars/audio/nested Pass_<id>_Textures. SourceAssembler injects #define Uniforms Pass_<id>_Uniforms before each kernel.
- ChannelBindings / iChannelN / channelCount gone.
- Kernel signature: two argbuffers — device const Uniforms& at [[buffer(0)]], device const UserUniforms& at [[buffer(1)]]. No more outTexture special parameter; writes go through uniforms.textures.<id>.write(...).
- gid declared as a file-scope global with [[thread_position_in_grid]] (also closes #28).
- All 36 examples ported and rendering. Generator instructions + document templates updated to teach the new shape.
- Validation: passHasNoOutput, readWriteHazard adjusted for new model.
- Asset loading via .image init still works end-to-end through the bundle.

Follow-ups already filed: #51 (sensible front-matter defaults), #54 (inter-pass swap timing for SwapTiming.immediate).

---

## 51: Sensible front-matter defaults: empty block should just work

+++
status: new
priority: low
kind: enhancement
created: 2026-06-19T16:44:13Z
+++

## Problem

Every new shader starts with a near-identical 10-line front-matter block:

    /* phosphor:environment
    output = "image"

    [[resources]]
    kind = "texture2D"
    id = "image"
    spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

    [[passes]]
    id = "image"
    output = "image"
    */

99% of single-pass procedural shaders want exactly this. The TOML is
copy/paste boilerplate.

## Goal

An empty (or nearly empty) front-matter block should default to a sensible
shape, so the simplest possible shader is:

    /* phosphor:environment */

    kernel void image(...) {
        outTexture.write(float4(1, 0, 0, 1), gid);
    }

## Proposed defaults

When the front-matter block is empty or omits a field:

- `output` defaults to `"image"`.
- If no `[[resources]]` are declared, synthesize one:
  `{ kind = "texture2D", id = "image", spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" } }`
- If no `[[passes]]` are declared, synthesize one:
  `{ id = "image", output = "image" }`

User can still override any of these by being explicit. The defaults kick
in only when fields are absent.

## Implementation notes

- Lives in the TOML decode step (or right after). Add a normalization
  pass that fills in absent fields before validation runs.
- Document the defaults in the generator's instructions string so the
  model can produce shorter front-matter for simple cases.
- Update the empty-document templates in PhosphorMetalDocument and
  PhosphorBundleDocument to use the minimal form.

## Open questions

- Should defaults apply when ALL fields are missing, or also when some are
  missing? E.g. if the user declares one resource but no passes, do we
  synthesize a pass that targets it? Probably yes \u2014 the rule is 'fill any
  gap with the canonical single-pass shape if it makes sense'.
- The synthesized pass id matches the kernel function name (`image`).
  Document that the kernel function must match the (defaulted or declared)
  pass id.

---

## 52: Resources are textures; init / swap are actions, not shapes

+++
status: closed
priority: medium
kind: feature
labels: architecture
created: 2026-06-19T16:46:29Z
updated: 2026-06-19T17:09:28Z
closed: 2026-06-19T17:09:28Z
+++

## Problem

Today the texture model is fragmented across three orthogonal concerns
that the model conflates:

1. **Resource "kind"**: `.texture2D(id, spec)` vs `.image(id, name, access)`.
   The `.image` shape is really 'a texture that happens to be seeded from
   a bundled asset' \u2014 it's not a separate kind, it's a texture with a
   particular init action.
2. **Initial contents**: `spec.initial = .image(name)` vs `.zero` vs
   `.color(\u2026)` vs `.noise(\u2026)`. Only `.zero` and `.image` are
   actually implemented; the rest are TODOs.
3. **Ping-pong flag**: `spec.pingPong: Bool` plus a separate
   `spec.flipTiming: .endOfFrame | .immediate` for when the swap happens.

Three different concerns, three different mechanisms, encoded as fields
on a struct + an enum case on the parent. The `.image` shape only exists
because it lets us skip pre-declaring size and format \u2014 not because it's
a fundamentally different kind of resource.

## Goal

Collapse to: 'a Resource is a texture. It has a size, a format, an access
mode. Things that happen *to* the texture (load an image, zero it, swap
ping-pong halves) are actions/modes, not extra resource shapes.'

## Proposed shape (sketch)

```toml
# Procedural single-pass shader, full defaults.
[[textures]]
id = "image"

# Sample image bound at init time. Size + format inferred from the asset
# (we don't make the user re-declare).
[[textures]]
id = "photo"
init = { kind = "image", name = "screenshot" }
access = "sample"

# Feedback buffer with explicit swap timing.
[[textures]]
id = "trail"
swap = "endOfFrame"        # or "none" (default) or "immediate"
```

Key moves:

- **No `.image` enum case.** Image-backed textures are just textures with
  `init = { kind = "image", \u2026 }`.
- **Init becomes an action**, with kinds: `zero` (default), `image`,
  `color`, `noise`. Each takes its own parameters in a nested table.
- **`swap`** replaces the `pingPong: Bool` + `flipTiming` pair. Values:
  `none` (default), `endOfFrame`, `immediate`.
- **Size and format become optional even for non-image textures**, with
  sensible defaults (`drawable` / `rgba32Float`). Image-backed textures
  derive them from the decoded asset; that derivation isn't an explicit
  case anymore, it's the result of running the init action.
- **`access`** stays per-resource (was added recently); read / sample /
  write / read_write per #50.

## Implementation notes

- One Resource case (just `.texture2D`, possibly renamed).
- TextureInit becomes a fully-modeled enum with payloads, all actually
  implemented (today only `.zero` and `.image` work).
- Swap timing moves out of the spec entirely and into runtime behavior
  derived from the `swap` field.
- Runtime keys ping-pong pairs by the texture id when `swap != .none`.

## Maybe-too-aggressive ideas

- Init actions could be re-triggerable as named passes the user can fire
  from the toolbar (so 'reseed feedback shader' becomes 'rerun the init
  action'). Out of scope for v1 \u2014 but the shape leaves room for it.
- Same with swap: today it's an automatic behavior; conceivably it could
  be an explicit `swap()` call inside the shader pipeline definition.

## Breaking changes

Every example shader's front-matter changes. ~35 files. Mostly mechanical.

## Related

- #1 added `.image(name:)` as a TextureInit case but the resource itself
  was still `.texture2D`. That was the first crack in this design.
- The new `.image` resource case (filed in this session) papered over
  the size/format-inference problem; that hack goes away under this
  redesign.
- #50 (unify outputs and channels) overlaps heavily \u2014 likely want to do
  the two together so the texture model is fully re-thought at once.

- `2026-06-19T17:09:28Z`: Folded into #50. Same scope, redesign covers both unified-bindings and resources-as-textures-with-action-init.

---

## 53: Debounce or wait-for-quiescent edit before recompiling shader

+++
status: closed
priority: medium
kind: bug
created: 2026-06-19T16:48:27Z
updated: 2026-06-21T05:24:21Z
closed: 2026-06-21T05:24:21Z
+++

After fixing a syntax error and the shader compiles fine, hitting space causes the syntax error to come back.

- `2026-06-21T05:24:21Z`: Debounced recompiles: parsing stays instant (live editor diagnostics) but the compile waits 300ms after the last keystroke via .task(id: text) + Task.sleep(for:). A new keystroke cancels/restarts, so mid-edit syntax errors no longer flicker back.

---

## 54: Inter-pass texture swaps: allow ping-pong parity flips between passes within a single frame

+++
status: new
priority: low
kind: feature
labels: speculative, architecture
created: 2026-06-19T17:30:17Z
+++

Speculative. Today the runtime's 'parity per resource' is set once per frame; ping-pong textures effectively swap only at end-of-frame. The same-frame-multi-pass case is partially handled (a later pass that samples a texture an earlier pass wrote sees the freshly written half), but there's no way to do a real *swap* between passes \u2014 i.e. pass B writes the next parity, pass C reads B's just-written half as if it were 'last frame's' contents.

Use cases:

- Multi-stage feedback chains where each pass contributes to a downstream pass's history.
- Per-chemical reaction-diffusion buffers iterated multiple times per frame.
- Jacobi-style convergent solvers (each pass = one iteration = one swap).

Out of scope for the #50 redesign, but the new per-binding access shape makes this much easier to add: the runtime can derive 'this pass writes the new parity, that pass reads the previous parity' directly from the binding declarations, rather than from a global pingPong + flipTiming flag.

Likely shape: `SwapTiming.immediate` (already modeled, today's #4) means 'flip parity right after this pass'. RFC-001 keeps that case in the enum but ships only `endOfFrame`.

---

## 55: Multi-shader .phosphord bundles with sidebar picker

+++
status: closed
priority: medium
kind: feature
labels: architecture
created: 2026-06-20T18:46:36Z
updated: 2026-06-21T04:30:14Z
closed: 2026-06-21T04:30:14Z
+++

Today a .phosphord bundle holds one shader.metal. Expand to many.

Bundle layout:

    Foo.phosphord/
      shaders/
        hello.metal
        plasma.metal
        ...
      assets/
        ...

UI: switch PhosphorBundleDocumentView to NavigationSplitView. Sidebar
on the left lists the shaders (and the assets row stays at the bottom
of the editor pane). Selecting a shader opens it in the existing
PhosphorEditorBody. The asset list is shared across all shaders in
the bundle.

Touch points:
- PhosphorBundleDocument: replace single 'text' with [String: String]
  keyed by shader filename. Snapshot/Reader/Writer updated; previous
  FileWrapper retained to keep unchanged shaders untouched on save.
- PhosphorBundleDocumentView: NavigationSplitView with sidebar +
  detail. Sidebar has a + button to create, hover/swipe to delete,
  inline rename.
- PhosphorEditorBody is unchanged — it still takes a Binding<String>
  + parsed + assets.
- Plain .metal documents stay single-file (no migration).

Open questions to decide during impl:
- Default shader filename for a brand-new bundle: 'shader.metal' stays
  for v1 compat? Or 'untitled.metal'?
- Which shader is 'active' on open? Last-edited (track in info.json)?
  First alphabetically? First created?
- Cross-shader references — out of scope for v1; each shader is its
  own environment.

- `2026-06-21T04:30:14Z`: Implemented: PhosphorBundleDocumentView uses NavigationSplitView with a BundleSidebar listing Sources + Assets; selecting a shader opens it in the shared editor.

---

## 56: Side-by-side mode: dragging splitter resizes window instead of panes

+++
status: closed
priority: low
kind: bug
created: 2026-06-20T20:15:30Z
updated: 2026-06-21T04:30:14Z
closed: 2026-06-21T04:30:14Z
+++

Repro: in side-by-side layout, drag the HSplitView splitter to give the editor more or less width. Instead of redistributing between editor and preview, the window itself grows or shrinks.

Likely cause: TextEditor inside MetalSourceView reports an intrinsic minimum size driven by the longest unbroken line of source. NSSplitView won't let the divider drop below that minimum, so any drag below the threshold pushes the window outward.

Possible fixes to try:

- `2026-06-20T20:15:30Z`: .frame(minWidth: 0) on CodePane to force-zero the lower bound (lets the editor clip / scroll horizontally instead of growing the window).
- `2026-06-20T20:15:30Z`: Wrap MetalSourceView in a horizontal ScrollView so its intrinsic width detaches from its content width.
- `2026-06-20T20:15:30Z`: Set NSSplitView's holding priority via a UIViewRepresentable bridge \u2014 invasive.
- `2026-06-21T04:30:14Z`: Fixed: ShaderEditorLayoutView sets .frame(minWidth: 300) on both code and preview panes so the HSplitView divider redistributes between panes instead of resizing the window.

---

## 57: Header popover needs minimum sizes

+++
status: closed
priority: low
kind: bug
created: 2026-06-21T00:02:57Z
updated: 2026-06-21T04:30:42Z
closed: 2026-06-21T04:30:42Z
+++

- `2026-06-21T04:30:42Z`: Header popover now has sensible minimum sizes.

---

## 58: User uniforms overlay should be anchored at bottom center of screen

+++
status: closed
priority: low
kind: enhancement
created: 2026-06-21T00:02:57Z
updated: 2026-06-21T02:33:05Z
closed: 2026-06-21T02:33:05Z
+++

---

## 59: User uniforms overlay should respect safe areas

+++
status: closed
priority: low
kind: bug
created: 2026-06-21T00:02:58Z
updated: 2026-06-21T02:33:06Z
closed: 2026-06-21T02:33:06Z
+++

---

## 60: App crashes when loading document (race condition with window sizing)

+++
status: closed
priority: high
kind: bug
created: 2026-06-21T00:03:03Z
updated: 2026-06-21T02:33:44Z
closed: 2026-06-21T02:33:44Z
+++

App often crashes when loading a doc, but not always — appears to be a race condition with window sizing. Crash log to be attached.

- `2026-06-21T00:06:23Z`: Root cause from crash log: window-sizing race produces a zero-width drawable.

CAMetalLayer ignoring invalid setDrawableSize width=0.000000 height=796.000000
[CAMetalLayer nextDrawable] returning nil because allocation failed.
MetalSprocketsSupport/Error.swift:50: Fatal error: Resource creation failure: No drawable available

Crash is in the MetalSprockets dependency (not Phosphor): MetalSprocketsUI/RenderView.swift, RenderViewViewModel.draw(in:):
  let currentDrawable = try view.currentDrawable.orThrow(.resourceCreationFailure("No drawable available"))

When drawableSize has a zero dimension during initial window sizing, currentDrawable is nil and orThrow fatal-errors instead of skipping the frame.

Fix belongs in schwa/MetalSprockets: early-return from draw(in:) when view.drawableSize.width <= 0 || height <= 0 (and/or guard-let currentDrawable to skip the frame). Then bump the MetalSprockets pin in Phosphor. Audio init lines in the log are unrelated noise.

- `2026-06-21T02:33:44Z`: Fixed in 47a47b75: PhosphorRunningView only mounts the render surface (MTKView) once viewSize has non-zero width/height, tracked via onGeometryChange. Prevents instantiating a Metal drawable at zero size during the window-sizing race.

---

## 61: Bundle UI: swipe to delete assets and shaders

+++
status: closed
priority: low
kind: feature
created: 2026-06-21T00:03:03Z
updated: 2026-06-21T04:48:16Z
closed: 2026-06-21T04:48:16Z
+++

- `2026-06-21T04:48:16Z`: Swipe-to-delete added for both Sources and Assets in BundleSidebar; PhosphorBundleDocument.removeShader(filename:) handles active-shader fixup.

---

## 62: Bundle UI: add filter/search to list

+++
status: new
priority: low
kind: feature
created: 2026-06-21T00:03:03Z
+++

---

## 63: Anthropic API key occasionally loads blank

+++
status: closed
priority: medium
kind: bug
created: 2026-06-21T00:14:01Z
updated: 2026-06-21T04:30:14Z
closed: 2026-06-21T04:30:14Z
+++

Intermittently the Anthropic API key fails to load and comes back blank. Likely a load-order/timing or keychain-read race.

- `2026-06-21T04:30:14Z`: Addressed: KeychainStore distinguishes transient read failures from missing items, logs the failing OSStatus, and writes with kSecAttrAccessibleAfterFirstUnlock; callers no longer treat a transient failure as a blank key. Closing as resolved.

---

## 64: Highlight sidebar on drag & drop of files

+++
status: new
priority: low
kind: enhancement
created: 2026-06-21T05:00:15Z
+++

When dragging files over the bundle sidebar drop target, give visual feedback (highlight the drop area) so the user knows it will accept the drop. Currently dropDestination accepts files but provides no hover highlight.

---

## 65: Handle selection of image assets

+++
status: new
priority: low
kind: feature
created: 2026-06-21T05:00:30Z
+++

In the bundle sidebar, asset rows aren't selectable/previewable. Selecting an image asset should do something useful — e.g. show a preview/thumbnail and metadata (dimensions, format) in the detail or inspector area.

---

## 66: Model display names show (possibly wrong) version numbers

+++
status: closed
priority: low
kind: bug
created: 2026-06-21T05:02:21Z
updated: 2026-06-21T05:12:25Z
closed: 2026-06-21T05:12:25Z
+++

Generate panel lists models with hardcoded version numbers in displayName: 'Claude Opus 4.5', 'Claude Sonnet 4.5', 'Claude Haiku 4.5' (ids claude-opus-4-5 / claude-sonnet-4-5 / claude-haiku-4-5 in ShaderGenerator.swift AnthropicModel). These versions are likely wrong/invented. Either drop the version numbers from the user-facing display names (just 'Claude Opus' etc.) or make sure the version numbers + model ids are actually correct.

- `2026-06-21T05:12:25Z`: Dropped version numbers from user-facing display names (now 'Claude Opus' / 'Claude Sonnet' / 'Claude Haiku'); model ids unchanged.

---

## 67: Infer texture size from image asset

+++
status: closed
priority: low
kind: feature
created: 2026-06-21T05:04:54Z
updated: 2026-06-22T03:52:35Z
closed: 2026-06-22T03:52:35Z
+++

When a texture is init = { kind = "image", file = ... }, allow omitting size so the texture is allocated at the decoded image's native dimensions. Today TextureSize only supports drawable/scaledDrawable/fixed, so an image-backed texture must hardcode size (e.g. mandrill is 512x512) or it's allocated at drawable size and the image is copied into the corner. Add a size mode (e.g. "image"/auto, or treat missing size on an image init as native) in TextureSize + Resource+Codable + PhosphorRuntime.pixelDimensions/allocate, and update TextureDemo.metal to use it.

---

## 68: Support more/all pixel formats

+++
status: new
priority: low
kind: feature
created: 2026-06-21T05:09:15Z
+++

PhosphorPixelFormat currently only exposes rgba8Unorm, bgra8Unorm, rgba16Float, rgba32Float. Expand to cover the rest of the useful MTLPixelFormat set (e.g. r8/rg8/r16f/rg16f/r32f/rg32f, rgba8Unorm_srgb/bgra8Unorm_srgb, rgb10a2, rg11b10f, etc.). Touch points: PhosphorPixelFormat enum (Resource.swift) + mtlPixelFormat() and bytesPerPixel switch in PhosphorRuntime.swift. Consider deriving bytesPerPixel from the format rather than a hand-maintained switch.

---

## 69: Rename files in the UI

+++
status: new
priority: low
kind: none
created: 2026-06-21T05:12:29Z
updated: 2026-06-21T05:54:41Z
+++

Add the ability to rename files (not directories) from the UI.

---

## 70: Export as Xcode project

+++
status: new
priority: medium
kind: feature
created: 2026-06-21T06:07:58Z
+++

Export a shader as a fully baked Xcode project.

---

## 71: ⌘⇧N (New Phosphor Bundle) not working

+++
status: new
priority: medium
kind: bug
created: 2026-06-21T06:14:42Z
+++

The `⌘⇧N` keyboard shortcut for 'New Phosphor Bundle' doesn't trigger.

Both New commands are defined in PhosphorApp.swift:
- `⌘N` → New Metal Shader
- `⌘⇧N` → New Phosphor Bundle (PhosphorApp.swift:24)

Likely cause: there are two DocumentGroup scenes (one per content type). The second DocumentGroup (.phosphorBundle) injects its own default New menu item, which conflicts with the custom MyNewDocumentButton shortcut in the first group's .commands { CommandGroup(replacing: .newItem) }. SwiftUI's handling of New commands across multiple DocumentGroups is the usual source of this.

Repro: launch app, press ⌘⇧N — nothing happens (or the wrong document type opens).

Not yet root-caused; needs verification.

---

## 72: Infer texture pixel format from image asset

+++
status: new
priority: low
kind: feature
created: 2026-06-22T03:49:21Z
+++

Companion to #67 (infer texture size from image asset).

When a texture is init = { kind = "image", file = ... }, allow omitting `format` so the texture's pixel format is inferred from the decoded asset instead of being hardcoded.

Today the format must be set explicitly (e.g. TextureDemo.metal hardcodes format = "bgra8Unorm" to match mandrill.png). Authors have to know the asset's encoding. PhosphorAsset already reads image metadata via ImageIO (see pixelSize()), so the bit depth / color model could drive a sensible PhosphorPixelFormat default.

Scope:
- Decide how 'infer' is expressed (e.g. omitting format on an image init, or an explicit sentinel).
- Map CGImage properties (bit depth, alpha, color space) to the closest PhosphorPixelFormat (rgba8Unorm / bgra8Unorm / rgba16Float / rgba32Float).
- Fall back to the current default (rgba32Float) when there's no image init or the asset is missing/undecodable.
- Update TextureDemo.metal to drop the hardcoded format once supported.

Note: PhosphorPixelFormat is a closed set; inference is best-effort to the nearest match, not exact format passthrough.

---
