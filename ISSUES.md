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
updated: 2026-06-24T22:45:32Z
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
kind: task
labels: effort:m
created: 2026-06-18T22:08:22Z
updated: 2026-06-24T22:45:39Z
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
kind: feature
labels: effort:l
created: 2026-06-18T22:08:49Z
updated: 2026-06-24T22:45:39Z
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
kind: feature
labels: effort:l, needs-info
created: 2026-06-18T23:20:38Z
updated: 2026-06-22T15:40:24Z
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

- `2026-06-22T15:40:24Z`: Related to #74 (AI prompt routing): both involve Shadertoy GLSL->MSL translation. #32 is URL/paste import; #74 is prompt classification/routing. Distinct features, shared translation dependency (#27).

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
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-06-19T00:59:05Z
updated: 2026-06-22T15:40:16Z
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
status: closed
priority: medium
kind: enhancement
labels: architecture, effort:l
created: 2026-06-19T02:15:39Z
updated: 2026-06-24T22:45:05Z
closed: 2026-06-24T22:45:05Z
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

- `2026-06-19T02:15:39Z`: `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PhosphorRuntime.swift`
- `2026-06-19T02:15:39Z`: `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PhosphorPipeline.swift`
- `2026-06-19T02:15:39Z`: `Packages/PhosphorSupport/Sources/PhosphorSupport/Runtime/PingPongTexture.swift`
- `2026-06-19T02:15:39Z`: Parts of `Packages/PhosphorSupport/Sources/PhosphorSupport/UI/PhosphorView.swift` (playback wiring)
- `2026-06-22T15:40:24Z`: Related to #54 (inter-pass parity flips): #54 builds on this runtime; deepening Runtime+Pipeline here should keep #54's same-frame swap use case in mind.
- `2026-06-24T22:45:05Z`: Out of date. The render orchestration has since moved into PhosphorKit (PhosphorRuntime + PhosphorPipeline in the PhosphorKit package), and the playback-clock/pause-reset concerns referenced here were already extracted (#43). The specific coupling described no longer reflects the current architecture.

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
status: open
priority: medium
kind: feature
labels: generation, effort:l
created: 2026-06-19T03:25:39Z
updated: 2026-06-22T15:49:24Z
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

- `2026-06-22T15:49:24Z`: Related to #77 (chat-like generation panel): the chat panel is the natural place to attach per-turn rendered previews.

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
status: open
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-19T16:44:13Z
updated: 2026-06-22T15:40:16Z
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
status: open
priority: low
kind: feature
labels: speculative, architecture, effort:l
created: 2026-06-19T17:30:17Z
updated: 2026-06-22T15:40:24Z
+++

Speculative. Today the runtime's 'parity per resource' is set once per frame; ping-pong textures effectively swap only at end-of-frame. The same-frame-multi-pass case is partially handled (a later pass that samples a texture an earlier pass wrote sees the freshly written half), but there's no way to do a real *swap* between passes \u2014 i.e. pass B writes the next parity, pass C reads B's just-written half as if it were 'last frame's' contents.

Use cases:

- Multi-stage feedback chains where each pass contributes to a downstream pass's history.
- Per-chemical reaction-diffusion buffers iterated multiple times per frame.
- Jacobi-style convergent solvers (each pass = one iteration = one swap).

Out of scope for the #50 redesign, but the new per-binding access shape makes this much easier to add: the runtime can derive 'this pass writes the new parity, that pass reads the previous parity' directly from the binding declarations, rather than from a global pingPong + flipTiming flag.

Likely shape: `SwapTiming.immediate` (already modeled, today's #4) means 'flip parity right after this pass'. RFC-001 keeps that case in the enum but ships only `endOfFrame`.

- `2026-06-22T15:40:24Z`: Related to #40 (deepen Runtime+Pipeline): this feature depends on the runtime's parity model; coordinate with that refactor.

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
status: open
priority: low
kind: feature
labels: effort:s
created: 2026-06-21T00:03:03Z
updated: 2026-06-22T15:40:16Z
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
status: open
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-21T05:00:15Z
updated: 2026-06-22T15:40:16Z
+++

When dragging files over the bundle sidebar drop target, give visual feedback (highlight the drop area) so the user knows it will accept the drop. Currently dropDestination accepts files but provides no hover highlight.

---

## 65: Handle selection of image assets

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-06-21T05:00:30Z
updated: 2026-06-22T15:40:16Z
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
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-06-21T05:09:15Z
updated: 2026-06-22T15:40:16Z
+++

PhosphorPixelFormat currently only exposes rgba8Unorm, bgra8Unorm, rgba16Float, rgba32Float. Expand to cover the rest of the useful MTLPixelFormat set (e.g. r8/rg8/r16f/rg16f/r32f/rg32f, rgba8Unorm_srgb/bgra8Unorm_srgb, rgb10a2, rg11b10f, etc.). Touch points: PhosphorPixelFormat enum (Resource.swift) + mtlPixelFormat() and bytesPerPixel switch in PhosphorRuntime.swift. Consider deriving bytesPerPixel from the format rather than a hand-maintained switch.

---

## 69: Rename files in the UI

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-06-21T05:12:29Z
updated: 2026-06-24T22:32:48Z
closed: 2026-06-24T22:32:48Z
+++

Add the ability to rename files (not directories) from the UI.

- `2026-06-24T22:32:48Z`: Added inline rename for shaders and assets in the bundle sidebar. PhosphorBundleDocument gains renameShader/renameAsset (undoable, preserve content + selection, reject empty/duplicate/unchanged names). Sidebar rows become an editable TextField via context-menu 'Rename' or swipe action; Return/focus-loss commits, Escape cancels.

---

## 70: Export as Xcode project

+++
status: open
priority: medium
kind: feature
labels: effort:xl
created: 2026-06-21T06:07:58Z
updated: 2026-06-22T15:40:16Z
+++

Export a shader as a fully baked Xcode project.

---

## 71: ⌘⇧N (New Phosphor Bundle) not working

+++
status: closed
priority: medium
kind: bug
created: 2026-06-21T06:14:42Z
updated: 2026-06-22T15:37:27Z
closed: 2026-06-22T15:37:27Z
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
status: closed
priority: low
kind: feature
created: 2026-06-22T03:49:21Z
updated: 2026-06-22T03:55:27Z
closed: 2026-06-22T03:55:27Z
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

## 73: Toolbar is a mess

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m
created: 2026-06-22T15:38:09Z
updated: 2026-06-22T22:09:27Z
closed: 2026-06-22T22:09:27Z
+++

The shader editor toolbar (ShaderEditorView.swift) crams ~10 controls into .principal placement with no grouping or overflow handling:

- Layout mode toggle
- Resource/preview picker
- Phosphor.h popover
- Uniforms panel toggle
- Frame-timing overlay toggle
- Microphone toggle
- Pause/Play
- Reset
- Generate
- Inspector toggle (.primaryAction)

Problems:
- Everything is .principal, so there is no logical grouping (playback vs. view options vs. actions).
- No overflow/ToolbarItemGroup handling; on narrow windows items get cut off or crowd the title.
- Mixed concerns sit side by side (a destructive-ish Reset next to a Generate sparkle next to view toggles).

Wants: group related controls, separate playback transport from view-options from actions, and handle narrow-window overflow gracefully. Consider ToolbarItemGroup, placement variety, and/or an overflow menu.

- `2026-06-22T22:09:27Z`: Reworked the editor toolbar: switched to .toolbar(id:) with stable per-item identifiers and CustomizableToolbarContent so it's user-customizable (right-click → Customize Toolbar) and ordering persists. Grouped by purpose and moved off the overstuffed .principal slot: .navigation (Layout, Resource), .principal (transport: Play/Pause, Reset), .automatic (Uniforms, Frame Timing, Mic, Phosphor.h), .primaryAction (Generate, Inspector). Frame Timing, Mic, and Phosphor.h are .defaultCustomization(.hidden) to cut default clutter. Added .toolbarRole(.editor). Closes #85 (per-item labels / display).

---

## 74: Planning mode: turn a vague idea or pasted shader into a concrete generation plan

+++
status: closed
priority: low
kind: feature
labels: effort:xl
created: 2026-06-22T15:39:19Z
updated: 2026-06-22T22:34:06Z
closed: 2026-06-22T22:34:06Z
+++

Add an optional planning stage before shader generation: a first model turn produces a structured-but-mostly-textual plan, shown in the transcript, that then drives the codegen turn. Separates "what are we building / how" from "write the code", improving vague prompts and pasted-source ports.

FINALIZED DESIGN (KISS):

Toggle, not always-on:
- Composer gets a persisted, default-OFF "Plan first" checkbox (@AppStorage). Off = today's single-turn path, untouched. On = plan turn then codegen turn. (Planning adds latency — two ~10-20s turns — so it's opt-in.)
- Applies to ALL prompts when on (fresh, port, modify).
- No user review/edit/accept. The plan is shown in the transcript for transparency and flows straight into codegen.

Schema — GeneratedPlan:
- Model-produced (@Generable): { intent: String (one-line summary), shape: PlanShape, plan: String (freeform prose: approach, build steps, Shadertoy->Phosphor mapping notes, edge-case decisions) }.
- PlanShape = singlePassImage | multiPass | feedback. The one structured field; high-value scaffolding hint (feedback -> codegen pre-builds ping-pong front-matter).
- Host-attached AFTER the turn (NOT in the @Generable schema, so the model never has to regurgitate/echo and can't truncate): { originalPrompt: String (verbatim user prompt), sourceCode: String (verbatim pasted GLSL/MSL, empty if none) }. The plan preserves the entire initial request + any pasted source.

Flow (ShaderGenerator.generate gains a `plan: Bool`):
- plan == false: unchanged.
- plan == true, SAME LanguageModelSession (KISS — no separate Planner port; reuse the session so the plan turn stays in history and codegen "remembers" it):
  1. Plan turn: plan-instruction prompt -> decode { intent, shape, plan } -> attach { originalPrompt, sourceCode } -> GeneratedPlan.
  2. Codegen turn: existing buildPrompt + the full plan serialized in (verbatim prompt + source + intent + shape + approach) -> existing compile/retry loop (unchanged).
- Plan is ADVISORY, not authoritative: codegen still produces the full GeneratedShader and may adapt; shape just nudges scaffolding.

UI:
- "Plan first" toggle in the composer (persisted, default off).
- New .plan transcript turn type: a distinct bubble (e.g. clipboard icon) with `intent` as a header and the prose body (collapsible), shown before the generated-shader turn. Reuse the existing two-turns-not-replaced pattern.

Notes:
- Shadertoy port mapping lives in the plan prose (KISS), shareable with #32.
- Persist plan in the front-matter/history later if useful; in-memory transcript for now.

Sub-tasks (build + test after each):
1. GeneratedPlan schema + plan instructions (GeneratorInstructions).
2. ShaderGenerator plan turn + thread plan into codegen (plan: Bool).
3. UI: composer toggle + .plan transcript turn.
4. Tests (fake port returns a scripted plan then a shader; verify two turns, plan attached, codegen prompt carries the plan).

Touchpoints: PhosphorSupport/Generation (ShaderGenerator, GeneratedShader/new GeneratedPlan, GeneratorInstructions, LanguageModelPort), GeneratePanel (toggle + plan turn), GenerationTurn.

- `2026-06-22T15:40:24Z`: Related to #32 (Shadertoy import): a 'shadertoyPort' sub-processor here overlaps with #32's GLSL->MSL translation path. Keep translation logic shareable.
- `2026-06-22T22:34:06Z`: Planning mode shipped. Optional, default-off 'Plan first' checkbox in the composer (persisted). When on, the same session runs a plan turn first (PlannedApproach {intent, shape, plan}) then the codegen turn built from the plan; verbatim prompt + pasted source attached host-side (GeneratedPlan), never round-tripped through the model. Plan shown as its own .plan transcript turn (no review/accept) and returned on GenerationResult.plan. KISS: reuses the session, no separate Planner port; plan is advisory + one structured  hint. Compile/retry loop unchanged. Tested via fake port (two turns, plan carried into codegen + result; off by default = no plan turn). Confirmed working against a live model.
- `2026-06-22T22:34:13Z`: Planning mode shipped. Optional, default-off "Plan first" checkbox in the composer (persisted). When on, the same session runs a plan turn first (PlannedApproach: intent + shape + plan prose) then the codegen turn built from the plan; verbatim prompt + pasted source attached host-side (GeneratedPlan), never round-tripped through the model. Plan shown as its own .plan transcript turn (no review/accept) and returned on GenerationResult.plan. KISS: reuses the session, no separate Planner port; plan is advisory plus one structured shape hint. Compile/retry loop unchanged. Tested via fake port (two turns, plan carried into codegen + result; off by default = no plan turn). Confirmed working against a live model.

---

## 75: Compatibility layers (Shadertoy et al.) toggled via a front-matter flag

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-06-22T15:42:17Z
updated: 2026-06-22T15:43:17Z
+++

Add opt-in compatibility layers that let a shader use the conventions of an external project (Shadertoy first, then potentially others like GLSL Sandbox, Bonzomatic, VESA/ISF) without hand-porting. The user turns a layer on with a front-matter flag, e.g.:

/* phosphor:environment
compatibility = "shadertoy"
output = "image"
*/

When a compatibility layer is active, Phosphor injects the right preamble/shims so the user's source 'just works' under that layer's conventions:

- Shadertoy layer: provide iTime, iResolution, iMouse, iFrame, iChannel0..3, iTimeDelta, iDate, etc. mapped to Phosphor builtins; wrap a mainImage(out float4 fragColor, in float2 fragCoord) entry point into a Phosphor kernel; handle the y-flip convention (ties into existing flipY). GLSL->MSL translation is still required for true GLSL source (#27); this flag is about the *uniform/entry-point/coordinate conventions* once you are in MSL.
- Future layers: each is a named compatibility profile that supplies its own header shims + entry-point adapter + default front-matter.

Design notes:
- Model: add a  field (enum/string) to PhosphorConfiguration; default none. Validate against known layer names.
- Source assembly: SourceAssembler / PhosphorHeader gains per-layer preamble injection. Keep the generated Phosphor.h preview accurate so users see what the layer provides.
- Interplay with flipY and builtin uniforms (BuiltinUniforms / PhosphorHeader).
- Should be discoverable in the UI (a picker that sets the front-matter flag), and the AI router (#74) could auto-select a layer.

Distinct from but related to:
- #27 (GLSL->MSL translation) — translation vs. convention-emulation; a Shadertoy import would likely use both.
- #32 (Shadertoy URL/paste import) — the importer could set compatibility = shadertoy on the result.
- #74 (AI prompt routing) — a shadertoyPort route could emit a shader that relies on this layer.

Touch points: PhosphorConfiguration (Model), SourceAssembler + PhosphorHeader (Source), BuiltinUniforms, front-matter parser/validator, configuration editor UI.

- `2026-06-22T15:42:30Z`: Correction to the front-matter example in the description (asterisks were stripped on entry). It should read:

/* phosphor:environment
compatibility = "shadertoy"
output = "image"
*/

---

## 76: All programmatic text mutations must be undoable

+++
status: closed
priority: high
kind: bug
labels: effort:m
created: 2026-06-22T15:47:11Z
updated: 2026-06-22T16:39:06Z
closed: 2026-06-22T16:39:06Z
+++

Several features mutate the document text directly, bypassing the editor's normal undo stack. After any of these runs, Cmd-Z does not restore the previous text (or behaves inconsistently). All text-modifying operations should register a single, coalesced undo step so the user can revert them.

Confirmed: there is no UndoManager / registerUndo usage anywhere in the app or PhosphorSupport today.

Operations that modify text and currently lack undo:
- Reformat front-matter (ReformatCommand / FrontMatterFormatter).
- AI generation / modify (GeneratePanel -> writes new source via the text binding + onTextChange, GeneratePanel.swift ~line 110).
- Configuration UI edits (PhosphorConfigurationEditorView) that rewrite the front-matter block.
- Any other path that assigns to document.text or activeText programmatically.

Requirements:
- Each operation registers one undo action (not per-character) with a clear action name (e.g. 'Reformat Front Matter', 'Generate Shader', 'Edit Configuration') so it shows in the Edit menu.
- Undo restores the full prior text; redo re-applies. Front-matter + body must stay consistent (re-parse after undo/redo).
- Works for both document types (PhosphorMetalDocument .text and PhosphorBundleDocument .activeText), and respects the active shader in a bundle.
- Plays nicely with the 300ms recompile debounce.

Open question: where undo registration lives. These are SDK 27 ReadableDocument/WritableDocument types (not NSDocument/FileDocument); confirm how to reach an UndoManager (SwiftUI @Environment(.undoManager) or document-owned). Centralizing text mutation behind one helper that registers undo is likely cleaner than per-call-site registerUndo.

Touch points: ReformatCommand, GeneratePanel, PhosphorConfigurationEditorView, PhosphorMetalDocument/PhosphorBundleDocument, ShaderEditorView.

- `2026-06-22T15:49:24Z`: Related to #77 (chat-like generation + version rollback): rollback and undo must be coherent — decide whether selecting an old version is an undoable text edit or a separate history mechanism.
- `2026-06-22T16:39:06Z`: Undo registration implemented: programmatic text mutations (Reformat, Generate/Modify, Edit Configuration) now route through PhosphorMetalDocument.setText / PhosphorBundleDocument.setText via the TextMutator helper, registering a single named undo step. Undo restores full prior text and re-parses; works for both document types. Redo does not yet work — split out into #79.

---

## 77: Move generation into the inspector as a chat-like panel with version rollback

+++
status: closed
priority: medium
kind: feature
labels: effort:l
created: 2026-06-22T15:49:19Z
updated: 2026-06-22T16:43:18Z
closed: 2026-06-22T16:43:18Z
+++

Rework the AI generation UX from the current modal GeneratePanel sheet into a persistent, chat-like panel hosted in the inspector (PhosphorInspectorView). Goals:

1. Inspector-hosted, non-modal
   - Move generation out of the .sheet (ShaderEditorView -> GeneratePanel) into the inspector so the user can iterate while watching the live preview.
   - Keep the existing model picker, progress phases (GenerationPhase: generating / retrying), and error surfacing.

2. Chat-like interaction
   - Show the conversation as a turn list: user prompts and the resulting shader versions, in order. Each user turn produced a shader; each assistant turn is 'generated vN' with title + a short summary/diff affordance.
   - Compose box at the bottom; follow-up prompts modify the current shader (existing 'modify existing source' flow already supports this).
   - PromptHistory already extracts prior prompts embedded in the source (PromptHistory.extract) -> reuse/extend as the backing transcript so history survives reopen.

3. Version rollback
   - Let the user jump back to any previous generated version and continue from there (branch the conversation).
   - Bundle documents (.phosphord): easy-ish — we control the on-disk tree, so we can store version snapshots (e.g. a versions/ or history sidecar) per shader and restore them.
   - Flat .metal documents: hard — a single text file with no place to stash history. Options to evaluate: (a) keep history only in-memory for the session, (b) encode a compact history into a front-matter/comment block (bloats the file), (c) an app-side sidecar/store keyed by file identity (fragile across moves/renames). Pick a pragmatic default and document the limitation.

Open questions:
- Transcript persistence model for each document type (in-memory vs. embedded vs. sidecar).
- How rollback interacts with undo (#76): is selecting an old version an undoable text edit, or a separate history mechanism?
- Diff/preview between versions.

Related:
- #76 (undoable text mutations) — generation writes text; rollback and undo should be coherent.
- #48 (rendered-frame screenshot feedback) — a chat panel is the natural place to show/attach rendered previews per turn.

Touch points: PhosphorInspectorView, GeneratePanel (becomes inspector content), ShaderEditorView (drop the sheet), ShaderGenerator / PromptHistory (transcript), PhosphorBundleDocument (version storage).

- `2026-06-22T16:43:18Z`: Split into #81 (move generation into the inspector, non-modal — straightforward) and #82 (chat-style UI + version rollback — the big piece). #82 depends on #81.

---

## 78: Decision: retire, limit, or keep flat .metal documents?

+++
status: new
priority: medium
kind: task
labels: needs-info, decision
created: 2026-06-22T15:49:43Z
updated: 2026-06-22T15:49:47Z
+++

DISCUSSION / DECISION — not a coding task yet.

We support two document types: flat .metal files (PhosphorMetalDocument) and .phosphord bundles (PhosphorBundleDocument). The flat .metal path is already a second-class citizen and the gap is widening. Should we retire it, formally limit it, or invest to keep it at parity?

Current capability gaps (.metal vs bundle):
- Assets: .metal has none. PhosphorDocumentView passes assets: [:] to runtime.reload (PhosphorDocumentView.swift:26); bundles pass real assets. So image-init textures / texture demos can't work in a flat file.
- Multiple shaders: bundles hold many shaders + a sidebar; .metal is single-source.
- Likely-future gaps: generation history / version rollback (#77) is 'easy-ish' for bundles, hard for .metal; any per-document sidecar state has nowhere to live in a single text file.

Options to weigh:
1. Keep at parity — invest to give .metal an asset story (e.g. inline base64, or a same-folder convention). Expensive and awkward; some features fundamentally want a container.
2. Limit / freeze — keep .metal as a lightweight 'single procedural shader, no assets' format. Document the limitation; features that need a container are bundle-only. Lowest effort, clearest mental model.
3. Retire — drop the flat .metal DocumentGroup; make .phosphord the only native document. Provide import (open a .metal -> wrap into a bundle) and export (write the active shader back out as .metal). Cleanest long-term, but a UX/compat change and removes the 'just open a .metal file' affordance.

Considerations:
- .metal is great for quickly opening/sharing a single file and for Shadertoy-style snippets (no assets needed).
- Most differentiating features (assets, multi-pass authoring, history) lean toward bundles.
- Whatever we choose affects #77 (rollback), #65 (asset selection), #51 (front-matter defaults), and the splash 'New Metal Shader' button.

Ask: which direction? Once decided, spin off concrete follow-up issues.

---

## 79: Redo not available after undoing a programmatic text mutation

+++
status: open
priority: high
kind: bug
labels: effort:s
created: 2026-06-22T16:39:02Z
updated: 2026-06-23T06:05:03Z
+++

Undoing a programmatic, undoable text mutation works, but Redo never becomes available afterward.

Symptoms observed (via the DEBUG-only 'Debug > Append Comment' command, which routes through the same TextMutator path as Generate/Reformat):
- Run Append Comment: the comment is appended to the document text.
- Edit menu shows 'Undo Append Comment' (action name correct).
- Cmd-Z: the comment is removed (undo restores prior text correctly).
- After undo, the Redo menu item stays greyed out / never lights up.

So undo registration and the action name work; only the redo step is missing. Same behavior was originally seen with Generate.

Infrastructure in place (from #76):
- PhosphorMetalDocument.setText(_:actionName:undoManager:) and PhosphorBundleDocument.setText(_:for:actionName:undoManager:) register undo via UndoManager.registerUndo(withTarget:), with the undo closure calling setText again to swap values (intended to provide redo for free).
- TextMutator bridges the doc-agnostic editor UI to those methods; injected via environment and re-published as a focused-scene value for menu commands.

Not yet root-caused; do not over-theorize here. Reproduce with the debug command, then investigate why the nested registerUndo inside the undo closure does not register as a redo action.

---

## 80: Layout button cycles HSplitView / VSplitView / ZStack

+++
status: closed
priority: low
kind: none
labels: effort:s
created: 2026-06-22T16:41:43Z
updated: 2026-06-22T16:41:45Z
closed: 2026-06-22T16:41:45Z
+++

Replaced the two-state side-by-side/overlay layout toggle with a three-state cycle button: horizontal (HSplitView), vertical (VSplitView), and overlay (ZStack). Icon and help text update per current state. Deduped the diagnostics/frame-timing/uniforms overlays into a shared PreviewOverlays modifier.

- `2026-06-22T16:41:46Z`: Implemented.

---

## 81: Move generation panel into the inspector (non-modal)

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-06-22T16:43:05Z
updated: 2026-06-22T16:50:31Z
closed: 2026-06-22T16:50:31Z
+++

Move AI generation out of the modal .sheet into the inspector (PhosphorInspectorView) so the user can iterate while watching the live preview. Straightforward relocation; no chat/history work here.

Scope:
- Add a generation tab/section to PhosphorInspectorView hosting the existing GeneratePanel content.
- Drop the .sheet (ShaderEditorView -> GeneratePanel) and the showGenerate state; the Generate toolbar button opens/focuses the inspector tab instead.
- Keep the existing model picker, progress phases (GenerationPhase: generating / retrying), and error surfacing.
- Keep the current single-prompt generate/modify flow as-is; chat-style turns and rollback are out of scope (see follow-up issue).

Touch points: PhosphorInspectorView, GeneratePanel (becomes inspector content), ShaderEditorView (drop the sheet).

- `2026-06-22T16:50:31Z`: Generation moved into the inspector as a non-modal 'Generate' tab. Dropped the .sheet; toolbar button + Cmd-Shift-P open the inspector and select the tab. Wider inspector via inspectorColumnWidth(min:360 ideal:480 max:900). Inspector force-opens to the Generate tab while a generation is in flight. Chat UI + rollback remain in #82.

---

## 82: Chat-style generation history UI

+++
status: closed
priority: medium
kind: feature
labels: effort:l
created: 2026-06-22T16:43:15Z
updated: 2026-06-22T17:09:12Z
closed: 2026-06-22T17:09:12Z
+++

Turn the inspector-hosted Generate tab (#81) into a chat-like view that keeps and displays a history of prompts and responses. No rollback/branching — that is #83.

Layout (Generate inspector tab):
- A chat-like list at the top showing the conversation in order: each user turn (the prompt) followed by the assistant turn (the resulting shader version, e.g. 'Generated v2' with a title / short summary).
- The text prompt field and model picker move to the BOTTOM of the tab (compose area), with the Generate/Modify button.
- Follow-up prompts modify the current shader (existing 'modify existing source' flow already supports this) and append a new turn.

History / persistence:
- Keep an in-session transcript of prompts + responses for display.
- PromptHistory already extracts prior prompts embedded in source (PromptHistory.extract) -> reuse/extend as the backing transcript where possible so some history survives reopen. In-memory is acceptable for v1; durable per-version storage is #83.

Out of scope (own issues):
- Version rollback / branching -> #83.
- Rendered-frame previews per turn -> relates to #48.

Touch points: PhosphorInspectorView (Generate tab), GeneratePanel, ShaderGenerator / PromptHistory (transcript model).

- `2026-06-22T17:09:12Z`: Chat-style generation history UI shipped: scrollable transcript (List) of user prompts + assistant turns over a bottom-pinned composer (prompt field, model picker, Generate/Modify). In-flight status distinguishes fresh vs. modify (with source byte count) and surfaces the actual Metal compiler errors on retry. Prior user prompts re-hydrate from PromptHistory on open. ShaderGenerator.generate now returns GenerationResult (source + title). Rollback/branching remain in #83.

---

## 83: Version rollback / branching for generated shaders

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-06-22T16:52:33Z
updated: 2026-06-23T06:05:03Z
+++

Let the user jump back to any previous generated version in the chat history (#82) and continue from there, branching the conversation. Split out of #82 — NOT part of the initial chat UI.

- Bundle documents (.phosphord): we control the on-disk tree, so store version snapshots (e.g. a versions/ or history sidecar) per shader and restore them.
- Flat .metal documents: hard — a single text file with no place to stash history. Evaluate: (a) in-memory only for the session, (b) compact history in a front-matter/comment block (bloats the file), (c) app-side sidecar keyed by file identity (fragile across moves/renames). Pick a pragmatic default and document the limitation.

Open questions:
- Transcript/version persistence model per document type (in-memory vs. embedded vs. sidecar).
- How rollback interacts with undo (#76/#79): is selecting an old version an undoable text edit, or a separate history mechanism?
- Diff/preview between versions.

Depends on #82 (chat history UI).

---

## 84: Add 'New Bundle' option to splash screen

+++
status: open
priority: medium
kind: feature
labels: effort:xs
created: 2026-06-22T16:55:19Z
updated: 2026-06-23T06:05:14Z
+++

The splash screen (Phosphor/Views/SplashScene.swift) only offers a single 'New Metal Shader' button. There is no way to create a new bundle (.phosphord) document from the splash screen, even though PhosphorBundleDocument exists. Add a 'New Bundle' button/action alongside 'New Metal Shader'.

---

## 85: Use 'icon and text' toolbar display mode for detail pane

+++
status: closed
priority: low
kind: enhancement
created: 2026-06-22T16:56:02Z
updated: 2026-06-22T22:09:26Z
closed: 2026-06-22T22:09:26Z
+++

Set the detail pane toolbar (NavigationSplitView detail in Phosphor/Views/PhosphorBundleDocumentView.swift) to display mode 'icon and text' if possible, so toolbar items show both their icon and label.

- `2026-06-22T22:09:26Z`: Folded into the #73 toolbar redesign.

---

## 86: Dark mode support

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-06-22T17:04:47Z
updated: 2026-06-24T22:41:46Z
closed: 2026-06-24T22:41:46Z
+++

- `2026-06-24T22:41:46Z`: App already works well in dark mode.

---

## 87: Tell the generator about the Phosphor.h helpers

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-06-22T17:17:46Z
updated: 2026-06-22T17:58:21Z
closed: 2026-06-22T17:58:21Z
+++

The shader-generation instructions (GeneratorInstructions) describe the Uniforms/UserUniforms/textures contract but never tell the model which helper functions and constants the synthetic Phosphor.h header already provides. As a result the model re-implements (or worse, calls non-existent) helpers.

Phosphor.h (PhosphorHeader.helpersDecl) currently provides:
- Constants: PI, PI2
- GLSL aliases: vec2/vec3/vec4
- rotate2D(angle), rotate3D(angle, axis)
- fsnoise(float2), fsnoiseDigits(float2)
- hsv(h,s,v)
- snoise2D / snoise3D / snoise4D
- F4 macro

Plan:
- Surface the available helpers to the model in GeneratorInstructions (list signatures + one-line descriptions; do NOT paste full bodies — keep token cost low, especially for the on-device compact variant).
- Tell the model these are already in scope (no need to define them) and not to redefine them.
- Keep it in sync with PhosphorHeader so the list doesn't drift; consider generating the signature list from a shared source of truth rather than hand-maintaining two copies.

Touch points: GeneratorInstructions (full + onDevice), PhosphorHeader.

- `2026-06-22T17:58:21Z`: The shader generator now receives the available Phosphor.h helpers as a declarations-only interface. PhosphorInterface.source derives this AT RUNTIME from the single source of truth (Phosphor.h) using the existing tree-sitter-cpp dependency: function bodies (compound_statement) are stripped, leaving signatures + doc comments; constants/macros/typedefs kept verbatim. Cached, with full-source fallback on parse failure. Large-context models get it appended under an 'AVAILABLE HELPERS (already declared — do not re-define, no #include)' heading; on-device stays compact. No generated file or script to keep in sync.

---

## 88: Store the static part of Phosphor.h on disk as a real header

+++
status: closed
priority: low
kind: enhancement
labels: effort:m
created: 2026-06-22T17:18:05Z
updated: 2026-06-22T17:44:00Z
closed: 2026-06-22T17:44:00Z
+++

Today the entire Phosphor.h prelude is synthesized in code (PhosphorHeader.helpersDecl) and there is no on-disk header — the user writes #include "Phosphor.h" purely as a hint and the runtime strips it before compiling.

Move the STATIC portion of the header (constants PI/PI2, GLSL aliases vec2/3/4, rotate2D/rotate3D, fsnoise/fsnoiseDigits, hsv, snoise2D/3D/4D, F4) out of helpersDecl() into a real .metal/.h resource file shipped in the app bundle (and copied into .phosphord packages where relevant). Keep the DYNAMIC, config-derived parts (per-pass Textures/Uniforms structs, UserUniforms) generated in code.

Benefits:
- Single source of truth for the helpers; easier to read/edit/syntax-highlight than a Swift triple-quoted string.
- Real file can be referenced for tooling, docs, and the in-app 'Phosphor.h' viewer.
- Sets up using it as actual context for generation (#87) by reading the file rather than duplicating signatures.

Open questions:
- Bundle as a SwiftPM resource (Bundle.module) in PhosphorSupport vs. app bundle vs. copied into each .phosphord package — pick based on who needs it at runtime vs. author time.
- For .phosphord: do we copy a physical Phosphor.h into the package so the include is real on disk, or keep stripping the include and only assemble in memory? Decide and document.
- Keep the SourceAssembler include-stripping behavior consistent with whatever we choose.

Touch points: PhosphorHeader (helpersDecl -> load from resource), SourceAssembler, PhosphorBundleDocument (if copying into packages), build/resource config. Relates to #87.

- `2026-06-22T17:44:00Z`: Extracted the static helper prelude (PI/PI2, vec aliases, F4, rotate2D/3D, fsnoise/fsnoiseDigits, hsv, snoise2D/3D/4D) into Resources/PhosphorHeader.metal as the single source of truth. PhosphorHeader.helpersDecl() now loads it via Bundle.module (process-cached, empty-string fallback). Dynamic config-derived structs stay code-generated. Decisions: bundled as a SwiftPM resource in PhosphorSupport, NOT copied into .phosphord packages — the include is still stripped and the header assembled in memory; SourceAssembler unchanged. Render/compile smoke tests pass.

---

## 89: Bake built-in textures into the app for shaders to use

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-06-22T17:21:41Z
updated: 2026-06-22T17:39:23Z
closed: 2026-06-22T17:39:23Z
+++

Ship a set of built-in textures with the app so shaders can reference them without the user importing anything. Resolve them the same way as bundled assets (TextureInit.image(file:) / texture inputs), but from an app-provided registry that's always available.

Initial set to bake in:
- Mandrill (the classic 'mandril'/baboon test image).
- A test card / color-bars calibration image.
- A variety of noise textures: white noise, value noise, Perlin/simplex, blue noise (good for dithering), and possibly a normal/curl-noise map. Provide a few resolutions or a single 512/1024 tile.

Scope / open questions:
- Where they live: SwiftPM resource in PhosphorSupport (Bundle.module) vs. the app bundle. Lean toward PhosphorSupport so the runtime that materializes textures owns them.
- Naming / namespace: reserve a prefix (e.g. 'builtin:mandrill', 'builtin:noise.blue') or a separate TextureInit case (.builtin(name:)) so they can't collide with user-imported assets. Decide and document.
- Asset lookup order: built-in registry vs. document/bundle assets (document assets should win on name collision, or be disallowed via the reserved prefix).
- Could the noise textures be generated procedurally at first use and cached instead of shipping bytes? Evaluate file-size vs. determinism (seeded).
- Surface them in the UI (texture-init picker / resource picker) so users can discover them.
- Generated shaders (#87) should know these exist.

Touch points: PhosphorAsset / asset registry, TextureInit + resolution path in PhosphorRuntime/ShaderCompiler, PhosphorConfiguration editor (TextureInitField image picker), resource bundling.

- `2026-06-22T17:39:23Z`: Built-in textures shipped in PhosphorSupport (Bundle.module): mandrill, BBC test card, and 5 noise variants (white, white-rgb, value, fBm, blue). Noise generated deterministically via Tools/generate_noise_textures.py. Reserved 'builtin:' namespace via BuiltinTextures registry; PhosphorRuntime.resolveAsset falls back to it so document assets still win for plain names. Generator schema gained GeneratedResource.imageFile (maps to TextureInit.image), and the instructions list the exact built-in names + usage so the AI can request them. 3D volume noise split into #92.

---

## 90: Extract source code editor into a generic SourceEditor target in PhosphorSupport

+++
status: open
priority: medium
kind: enhancement
labels: effort:l
created: 2026-06-22T17:25:10Z
updated: 2026-06-23T06:05:14Z
+++

Move the source-code-editor-related code out of the Phosphor app target and into a new, dedicated target in the PhosphorSupport package. Make it generic — a general-purpose syntax-highlighted source code editor, not tied to shaders/Metal.

## Code to extract (currently in app target)
- `Phosphor/Views/MetalSourceView.swift` — tree-sitter-highlighted text view (read-only + editable via Binding<String>). Generalize: rename away from 'Metal', make grammar/language selectable rather than hard-coded to C++/TOML.
- `Phosphor/Views/SyntaxPalette.swift` — color palette for highlighting (`.default`, `.dark`).
- `Phosphor/Views/CodePaneView.swift` — thin editable wrapper (currently Metal-flavored; generalize or drop the Metal-specific bits).

## Dependencies to move into the new target
- swift-tree-sitter (SwiftTreeSitter, SwiftTreeSitterLayer)
- tree-sitter-cpp (TreeSitterCPP)
- tree-sitter-toml (TreeSitterTOML)
These are already deps of PhosphorSupport; the new target should own the tree-sitter ones. Consider making language grammars pluggable so the editor target itself stays language-agnostic and callers register grammars.

## Design goals
- New target should be reusable as a standalone general-purpose source editor (no shader/Phosphor-specific knowledge).
- Public API: read-only display + editable binding, configurable language/grammar, configurable color palette.
- Shader-specific pieces (e.g. ShaderEditorView, PhosphorHeader display) stay in the app and consume the new target.
- Build and run tests after the move.

---

## 91: Built-in MetalFX spatial AI upscaling support

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-06-22T17:26:14Z
updated: 2026-06-23T06:05:14Z
+++

Add built-in support for MetalFX spatial scaling (MTLFXSpatialScaler) so shaders can render at a lower internal resolution and be AI-upscaled to the display resolution.

## Goals
- Render the shader pipeline at a reduced internal resolution, then upscale to output size via MetalFX spatial scaler.
- Expose an enable toggle + scale factor (e.g. 50% / 67% / 75%, or arbitrary) in the editor/inspector UI.
- Persist the setting per-document or as a UI preference.

## Notes
- Use `MTLFXSpatialScaler` (spatial, not temporal — no motion vectors needed for fragment-style shader output).
- Pick appropriate color processing mode (perceptual vs linear) based on the pipeline's output color space.
- Handle resize: recreate the scaler when input/output dimensions change.
- Gracefully degrade / hide the feature where MetalFX spatial is unsupported.

Out of scope for this issue: MetalFX temporal scaling.

- `2026-06-22T17:27:09Z`: MetalSprockets core already provides a `MetalFXSpatial` element (Sources/MetalSprockets/Metal/MetalFXSpatial.swift):

    public struct MetalFXSpatial: Element, BodylessElement {
        public init(inputTexture: MTLTexture, outputTexture: MTLTexture)
        // wraps MTLFXSpatialScalerDescriptor / MTLFXSpatialScaler
    }

So we don't need to write the scaler from scratch — wire this element into the Phosphor pipeline. (MetalSprockets also has MetalFXTemporal + RFC 0001 for temporal, out of scope here.) MetalSprocketsAddOns has no MetalFX support; the core package is the place to source it from.

---

## 92: Support 3D noise textures (volume textures)

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-06-22T17:33:22Z
updated: 2026-06-23T06:05:03Z
+++

Add 3D (volume) noise textures to the built-in set so shaders can do proper volumetric / domain-warped effects (clouds, smoke, marble, flow fields) by sampling a tileable 3D field instead of stacking 2D lookups.

Why worthwhile:
- Tileable 3D value/Perlin/worley noise is the natural primitive for raymarched volumes, domain warping, and animated 3D fields (sample at (xy, time)).
- Avoids the common hacks: 2D-noise-as-3D, or packing slices into a 2D atlas.

Big caveat — this is NOT just adding files. The runtime is currently 2D-only:
- PhosphorHeader emits `texture2d<float, access::...>` for every binding; sampling is `.read(gid)` (2D coords).
- TextureInit.image(file:) decodes a single 2D CGImage; PhosphorRuntime materializes MTLTexture as 2D.
- The @Generable schema + GeneratorInstructions assume 2D.

Scope to evaluate:
- A 3D texture resource kind (texture3d) end to end: model -> config -> MTLTextureType.type3D -> per-pass Textures struct field type -> sampling helper (`.sample(sampler, float3 uv)` / `.read(uint3)`).
- How a built-in 3D noise ships: a raw volume blob (RGBA8/float, WxHxD) + a small loader, since CGImage can't represent a volume. Generate with Python (extend Tools/generate_noise_textures.py): value/Perlin/worley, tileable, seeded.
- Sizes: 32^3 or 64^3 is usually plenty; keep file size sane.
- Built-in names + namespace (builtin:noise3d-value, builtin:noise3d-perlin, builtin:noise3d-worley).
- Teach the generator (instructions + schema) about 3D textures and how to sample them.
- UI: texture-init picker should distinguish 2D vs 3D.

Open questions:
- Is a shipped volume blob worth the bytes vs. generating procedurally on the GPU at load? A small seeded compute pass could synthesize the volume into a texture3d at materialization, possibly better than shipping data. Evaluate.
- Do we also want 2D array textures? Probably out of scope.

Relates to #89 (2D built-in textures) and #87 (generation context).

---

## 93: Generation trace: click a chat turn to see the full prompt sent

+++
status: open
priority: low
kind: enhancement
labels: effort:m
created: 2026-06-22T19:48:18Z
updated: 2026-06-23T06:05:18Z
+++

Each assistant turn in the Generate chat (#82) currently shows only a title + elapsed time. Capture a richer "generation trace" per turn and let the user click the turn to open a popover with the full details — primarily what was actually sent to the model, for transparency and debugging.

Proposed popover contents (per assistant turn):
- The user prompt, verbatim.
- The full request body assembled by ShaderGenerator.buildPrompt (the EXISTING SHADER block for modifies, the bare prompt for fresh). This is the genuinely useful "what did we send."
- Disclosure to reveal the full system instructions (GeneratorInstructions.instructions(for:) incl. the appended Phosphor.h interface) — long, so hidden by default.
- Model name + elapsed time.
- Retry info: whether a compile-retry happened, and the Metal compiler error that was fed back.
- Decoded result summary from the GeneratedShader (title, resource/pass/uniform counts, flipY, outputResourceID).

Generable caveat (document in code): with @Generable, FoundationModels decodes structured content directly into GeneratedShader — there is NO raw model text response to show. The popover shows the assembled REQUEST and the DECODED result, not a literal model token stream.

Implementation sketch:
- Introduce a GenerationTrace value (prompt, requestBody, instructions, model, elapsed, didRetry, compileError?, result summary).
- ShaderGenerator.generate returns it alongside source+title (extend GenerationResult or add a sibling), threaded up into the GenerationTurn.
- GeneratePanel: make assistant turns tappable -> .popover showing the trace. Keep it copyable (textSelection).
- In-memory only for now (consistent with the session transcript; durable storage is #83).

Sets up #48 (attach the rendered-frame screenshot to the same trace) and #74 (attach the plan).

Touch points: ShaderGenerator, GenerationResult/new GenerationTrace, GenerationTurn, GeneratePanel.

- `2026-06-23T06:05:18Z`: Related to #105 (verbose model logging): #93 surfaces a per-turn subset in the UI; #105 is the full off-by-default log.

---

## 94: Retry once on malformed/schema-decode response (feed the error back)

+++
status: closed
priority: medium
kind: enhancement
labels: generation, effort:s
created: 2026-06-22T19:49:40Z
updated: 2026-06-22T21:27:39Z
closed: 2026-06-22T21:27:39Z
+++

When the model returns a response that fails to DECODE into the GeneratedShader schema, the generator gives up immediately with a malformedResponse error (e.g. observed: {"$PARAMETER_NAME": "undefined"} — no title, garbage content). We already retry once when the produced shader fails to COMPILE (#30), feeding the compiler errors back. Do the same for malformed/schema-decode failures: feed the decode error back and retry.

Budget: AT MOST 1 retry to fix (one additional attempt), same as the compile retry. The two are part of the SAME overall budget — a request gets at most one corrective retry total, whether the first failure was a compile error or a decode/schema error. Do not stack two separate retries.

Where it lives (decision needed):
- The decode failure currently happens INSIDE FoundationModelAdapter.respond(to:), which throws malformedResponse before ShaderGenerator sees anything. The compile retry lives in ShaderGenerator.
- Preferred: surface a typed "malformed/decode" error from the port and let ShaderGenerator own a single unified retry policy that handles compile errors AND decode errors the same way (one attempts budget). Avoid hiding retry logic inside the adapter.

Retry prompt: tell the model its previous response didn't match the required schema, include the underlying decode error, and ask for a complete object with all required fields (title, body, resources, passes, uniforms, outputResourceID, flipY). The session already retains history.

Caveat to keep in mind: the observed $PARAMETER_NAME/undefined failure may be a backend/tool-calling glitch in the Anthropic adapter (a literal placeholder leaking through) rather than a model-comprehension problem. A retry is still worth it (cheap, often transient) but may hit the same glitch; don't assume the retry always fixes it.

Surface in the chat: if the single retry also fails, show the malformedResponse error as today.

Touch points: ShaderGenerator (unified retry policy + budget), LanguageModelPort/FoundationModelAdapter (typed decode error), GenerationPhase (a retrying-on-malformed phase or reuse), tests.

- `2026-06-22T19:51:47Z`: Validated manually: pasting the malformedResponse error back into a follow-up prompt ('i tried this before and got - malformedResponse(...)') produced a successful generation ('Pixelated Tube Fall'). Confirms feeding the decode error back recovers, and that this specific failure was transient/recoverable rather than a hard backend dead-end. Good evidence the automated single-retry is worth building.
- `2026-06-22T21:27:39Z`: Implemented, mirroring the compile-retry flow. A malformed/schema-decode failure on the first attempt feeds the decode error back (buildMalformedRetryPrompt) and retries once. Single corrective-retry budget shared with the compile retry — never stacked (tested). Adds GenerationCorrection.Kind.decode + GenerationPhase.retryingMalformed; the failure is recorded on GenerationResult.corrections and logged. UI: shows as its own .retried(.malformed) turn matching the compile-retry style. Tests cover decode-retry success, no-stacking, and give-up-after-one.

---

## 95: Make the generation transcript text selectable

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-22T19:50:59Z
updated: 2026-06-22T20:03:48Z
closed: 2026-06-22T20:03:48Z
+++

Make the Generate chat transcript text selectable/copyable everywhere it reasonably can be. Today only the in-flight status detail (compiler errors) and the error-turn message have .textSelection(.enabled); user prompt bubbles and assistant turns (title + summary) are not selectable, so you can't copy a prompt back out or copy an error/title.

Scope:
- User prompt bubbles (TurnRow .user): enable selection so prompts can be copied/reused.
- Assistant turns (TurnRow .assistant): enable selection on the title and summary.
- Keep the already-selectable error turn and status detail.
- Apply .textSelection(.enabled) at the appropriate container so all Text inside a turn is selectable; verify it doesn't break the tap target for the upcoming trace popover (#93).

Notes:
- Labels with an SF Symbol: only the text portion is selectable; that's fine.
- Don't enable selection on interactive controls (model picker, buttons).

Touch points: GeneratePanel TurnRow (user/assistant/error branches).

- `2026-06-22T20:03:48Z`: Applied .textSelection(.enabled) at the TurnRow level, so user prompts, assistant titles/summaries, the corrections disclosure, and error text are all selectable/copyable. Composer controls are unaffected (separate view).

---

## 96: Keep compile/correction error info around after auto-correct (don't drop it)

+++
status: closed
priority: medium
kind: enhancement
labels: generation, effort:s
created: 2026-06-22T19:55:38Z
updated: 2026-06-22T20:01:07Z
closed: 2026-06-22T20:01:07Z
+++

When a generated shader fails to compile, we surface the error transiently (the in-flight status shows "First attempt didn't compile — retrying" plus the compiler errors) and then auto-correct. After a successful retry the error is DISCARDED: GenerationStatus lives only in @State and is reset to nil in the defer, so nothing about the original failure survives in the transcript or any log. The same will be true of future error classes (e.g. malformed/decode failures, #94).

Goal: keep error info around even after a successful correction, so the user (and we) can see what went wrong and how it was fixed.

Scope:
- Record each failed attempt's error (compile error today; later decode/validation/runtime errors) as part of the turn's history, not just the transient status.
- Surface it in the chat: e.g. the successful assistant turn notes "auto-corrected 1 compile error" and the error text is viewable (likely folds into the generation trace popover, #93).
- Persist it with the turn for the session (in-memory is fine for now; durable storage is #83).
- Also log it (os.Logger) so it's recoverable from the system log regardless of UI — the generator already logs generations; make sure the triggering error is logged, not just dropped.

Notes:
- Generalize beyond compile errors: model the per-attempt outcome (attempt N, error kind, error text) so #94's decode-retry and any future retries reuse it.
- Don't bloat the happy-path UI: keep the corrected error tucked behind the trace/disclosure, with a short "auto-corrected" affordance on the turn.

Touch points: ShaderGenerator (return per-attempt error history), GenerationStatus/GenerationTurn (carry attempt outcomes), GeneratePanel (surface in turn + trace #93), generator logging.

- `2026-06-22T20:01:07Z`: Compile errors that trigger an auto-correct are now kept: ShaderGenerator records them on GenerationResult.corrections (modeled generically via GenerationCorrection so #94's decode retry can reuse it) and logs them via os.Logger before retrying. The successful assistant turn shows a collapsible 'Auto-corrected N compile error(s)' disclosure with the selectable error text; collapsed by default. In-memory for the session; folds into the trace popover (#93) later.

---

## 97: App launches with a transient 'missing asset' red banner that immediately disappears

+++
status: open
priority: medium
kind: bug
labels: effort:s
created: 2026-06-22T20:03:23Z
updated: 2026-06-23T06:05:03Z
+++

On app launch (opening a document / example), a red diagnostics banner briefly appears reading something like "asset '<name>' missing ... — texture zero-filled" and then disappears on its own a moment later. It's a transient flash, not a persistent error — the shader renders fine once it settles.

Repro: launch the app and open a shader (especially one with an image-init texture / asset). Watch the top-left diagnostics overlay on first paint.

Hypothesis (NOT yet verified — needs confirming): the diagnostics come from PhosphorRuntime during the first parse/compile pass, before assets/textures are fully wired up. The editor reloads on a 300ms debounce, and the initial reload may run with an empty/incomplete asset registry (or before built-in/document assets are resolved), emitting a missingAsset diagnostic that's then cleared on the next reload once assets are present. So it's a startup ordering/race in how diagnostics are computed vs. when assets are available, surfaced by DiagnosticsView (the missingAsset case).

Goal: don't show asset-missing (or any transient startup) diagnostics that are immediately invalidated. The banner should only appear for genuinely missing assets, after things have settled.

Investigation steps:
- Confirm the source: log/inspect runtime.diagnostics over the first ~second of launch; see whether a missingAsset diagnostic appears then clears.
- Determine whether the first reload runs without the asset registry (timing vs. asset injection) and whether built-in texture resolution (#89) is in the path.
- Decide the fix: suppress diagnostics until the first settled compile, debounce/clear stale diagnostics, or ensure assets are present before the first reload that can emit missingAsset.

Touch points: PhosphorRuntime (diagnostics timing), DiagnosticsView (missingAsset rendering), the editor reload task (PhosphorDocumentView / PhosphorBundleDocumentView 300ms debounce), asset injection.

---

## 98: Store prompts/instructions in resource files, not Swift string literals

+++
status: closed
priority: low
kind: enhancement
labels: effort:m
created: 2026-06-22T22:35:20Z
updated: 2026-06-23T01:32:00Z
closed: 2026-06-23T01:32:00Z
+++

Move the large prompt/instruction strings out of Swift triple-quoted literals into their own resource files (loaded via Bundle.module, cached), the way Phosphor.h now works (#88). They're long prose, awkward to read/edit/diff inside Swift, and mixing them with code makes both harder to maintain.

Candidates (PhosphorSupport/Generation):
- GeneratorInstructions.full (the big cloud/Anthropic system prompt)
- GeneratorInstructions.onDevice (the compact on-device system prompt)
- GeneratorInstructions.planning (the planning-turn instructions)
- The prompt-builder bodies in ShaderGenerator: buildPrompt, buildPlanPrompt, buildCodegenPrompt, buildRetryPrompt, buildMalformedRetryPrompt.

Design:
- Static instruction texts (full, onDevice, planning) -> plain resource files (e.g. Resources/Prompts/instructions-full.md, instructions-ondevice.md, planning.md). Load lazily + cache, empty-string fallback if missing, exactly like PhosphorHeader.staticHelperSource.
- The build*Prompt functions are NOT static — they interpolate runtime values (userPrompt, existingSource, compileError, decodeError, the plan). So they're TEMPLATES, not constants. Two options: (a) store the surrounding boilerplate as a resource with simple {placeholder} tokens and substitute in code, or (b) leave the interpolation in Swift but move only the long static preamble blocks to files. Pick the simpler one per case; full string interpolation is fine to keep in Swift where the template is short and mostly placeholders.
- Keep availableHelpersSection composition in code (it wraps PhosphorInterface.source, already a resource).
- Bundle as SwiftPM resources in PhosphorSupport (.copy), same pattern as Phosphor.h and the built-in textures.

Acceptance:
- No behavior change to generated prompts (round-trip identical text). Add a quick test that the loaded instruction files are non-empty and contain a known marker (e.g. 'kernel void').
- Single source of truth; .md files are readable/diffable on their own.

Touch points: GeneratorInstructions, ShaderGenerator (build*Prompt), Package.swift (resources), new Resources/Prompts/*.md. Relates to #88 (Phosphor.h on disk).

- `2026-06-23T01:32:00Z`: Moved the static generator instruction blocks (full, onDevice, planning) into PhosphorGeneration/Prompts/*.md, loaded via a cached loadPrompt(_:) that fatalErrors on missing/unreadable (same convention as Phosphor.h / StarterTemplate). The build*Prompt template functions stay in Swift (they interpolate runtime values). Note: stripped a stray 4-space indent the full/onDevice strings carried from Swift multiline-literal indentation — semantically irrelevant in a system prompt. Tests pass.

---

## 99: Persist generation transcripts as JSON; export writes that log

+++
status: closed
priority: medium
kind: feature
labels: generation, effort:m
created: 2026-06-22T22:36:14Z
updated: 2026-06-23T01:32:35Z
closed: 2026-06-23T01:32:35Z
+++

Persist the AI generation transcript to disk as JSON by default, and make "export" simply write out that JSON log. Today the chat transcript (GenerationTurn list in GeneratePanel) is in-memory only and lost on close.

Default persistence:
- Write a structured JSON log to Application Support (e.g. ~/Library/Application Support/Phosphor/GenerationLogs/), or another appropriate per-app dir. Decide keying: per-document (keyed by document identity / bookmark) vs. a single rolling app-wide log vs. per-session. Lean per-document so a doc's history travels with it, with a global fallback for documents with no stable identity (flat .metal; see #78).
- Append/update as generation happens; survive app relaunch and reopen of the transcript.

Capture as much as we reasonably can per turn/run:
- Timestamps (start/end), elapsed.
- User prompt (verbatim), model id/displayName, planning on/off.
- Plan (GeneratedPlan: intent, shape, plan prose, originalPrompt, sourceCode) when present.
- The assembled request actually sent (buildPrompt/buildCodegenPrompt body) and the full instructions used — ties into the trace popover (#93) and keep-error-info (#96).
- Each attempt's outcome: success, or corrections (GenerationCorrection: compile/decode + message). Retries.
- The resulting GeneratedShader summary (title, resource/pass/uniform counts, flipY, output) and/or the final source.
- Errors (terminal failures).

Export:
- "Export Transcript…" just serializes/copies the on-disk JSON log (fileExporter, JSON UTType). No separate export format/codepath — export == the log.
- Optionally also offer a human-readable Markdown rendering later; JSON is the source of truth.

Design notes:
- Make GenerationTurn (and the supporting types) Codable; define a stable, versioned on-disk schema (include a schemaVersion) so we can evolve it.
- Keep PhosphorSupport types (GenerationResult, GeneratedPlan, GenerationCorrection) Codable where they aren't already; the log model can live app-side and reference them.
- Privacy: this stores prompts + source on disk. Fine for a local dev tool, but note it; consider a setting to disable logging.
- This supersedes the in-memory-only note in #82/#83 for transcript persistence (versions/rollback #83 can build on this log).

Touch points: new GenerationLog store (app-side), GeneratePanel (write turns as they happen + load on open), Codable conformances in PhosphorSupport, fileExporter for export, a Settings toggle. Relates to #82, #83, #93, #96, #78.

- `2026-06-23T01:32:36Z`: Shipped. Generation transcripts persist as JSON to Application Support (per-document for saved docs; in-memory for unsaved), and Export Transcript writes that same log. The model is nested and reproducible: GenerationLog -> interactions -> exchanges, where each exchange is self-contained (instructions, request, decoded response or error, producedSource) and each interaction carries sourceBefore. Versioned schema (v3), Codable throughout. The privacy/disable toggle was intentionally dropped per request; per-document keying chosen over app-wide.

---

## 100: Add a Stop button to cancel an in-flight generation

+++
status: closed
priority: medium
kind: feature
labels: generation, effort:s
created: 2026-06-22T22:45:51Z
updated: 2026-06-24T22:26:53Z
closed: 2026-06-24T22:26:53Z
+++

Add a way to cancel an in-flight generation. Today once you hit Generate/Modify there's no stop — you wait out the model turn(s), which can be 10-40s (worse with planning mode's two turns). The Generate button shows a spinner but isn't actionable.

UI:
- While isGenerating, turn the Generate/Modify button (or add an adjacent one) into a Stop button (e.g. stop.fill / xmark), wired to cancel.
- On cancel: stop the spinner, leave the transcript as-is (the user prompt turn stays; optionally append a 'Cancelled' note), re-enable the composer, refocus the prompt.

Mechanics:
- generate() runs in a Task spawned from submit(); keep a handle to it (@State var generationTask: Task<Void, Never>?) and call .cancel().
- ShaderGenerator.generate is async and awaits model.respond / respondPlan. Cancellation needs to propagate: check Task.isCancelled at await points and after each model turn, and have the port honor cancellation. FoundationModels' LanguageModelSession.respond should throw CancellationError when the surrounding Task is cancelled — verify; if not, we may only be able to stop BETWEEN turns (e.g. after the plan turn, before codegen; or before a retry) rather than mid-request.
- Treat CancellationError specially: do NOT surface it as a .error turn; just unwind quietly.
- Make sure the defer cleanup (isGenerating=false, onGeneratingChange(false), refocus) still runs.

Open questions:
- Can we cancel mid-model-call, or only between turns? Document whatever the backend actually supports (don't claim mid-request cancel if FoundationModels won't honor it).
- If we cancelled after text was already applied (shouldn't happen — we apply only after the full result), ensure no partial writes.

Touch points: GeneratePanel (Stop button + Task handle + cancel + CancellationError handling), possibly ShaderGenerator (cancellation checks between turns), LanguageModelPort/FoundationModelAdapter (confirm respond honors cancellation).

- `2026-06-24T22:26:53Z`: Already implemented. ConversationStore.send runs in a cancellable sendTask; stop() calls sendTask?.cancel(), sets isGenerating=false and clears the task. CancellationError is caught and unwound quietly (not surfaced as an .error turn). GeneratePanel shows a Stop button (stop.fill) while generating, wired to store.stop().

---

## 101: Composer: Shift+Enter inserts newline (Enter still sends)

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-22T22:46:16Z
updated: 2026-06-23T03:55:16Z
closed: 2026-06-23T03:55:16Z
+++

In the generation composer, Enter submits the prompt (.onSubmit(submit)) and there's no good way to insert a newline — so writing a multi-line prompt (pasting a shader, describing several requirements) is awkward. Standard chat-composer behavior: Enter = send, Shift+Enter = newline.

Goal:
- Shift+Enter inserts a newline in the prompt; plain Enter sends.
- Keep the field growing 2...6 lines as now.

Approach:
- The current control is `TextField(..., axis: .vertical)` with `.onSubmit`. A plain TextField's onSubmit fires on Enter and there's no built-in Shift+Enter-for-newline affordance.
- Options to evaluate:
  (a) Keep TextField(axis:.vertical) and intercept the keyboard: a Shift+Enter key handler that inserts "\n" while plain Enter calls submit. On macOS this likely needs an .onKeyPress(.return) handler (return .handled to send when no modifiers; return .ignored when Shift is held so the newline is inserted). Verify .onKeyPress modifier detection works inside a focused TextField.
  (b) Switch to a TextEditor for the prompt and handle Enter/Shift+Enter explicitly (TextEditor inserts newlines by default, so we'd intercept plain Enter to submit). TextEditor gives more control but loses TextField niceties (placeholder, rounded border) — we'd restyle.
- Prefer the lightest approach that actually works; don't over-build. If .onKeyPress on TextField handles it cleanly, keep TextField.

Acceptance:
- Plain Enter sends (unchanged).
- Shift+Enter inserts a newline and the field grows.
- Multi-line prompts submit correctly.

Touch points: GeneratePanel composer (prompt TextField/onSubmit, possibly TextEditor + onKeyPress).

---

## 102: Collapse large user prompts behind a disclosure in the transcript

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-22T22:46:44Z
updated: 2026-06-23T03:29:14Z
closed: 2026-06-23T03:29:14Z
+++

Large user-prompt bubbles in the generation transcript (TurnRow .user) dominate the chat — pasting a whole Shadertoy/GLSL shader or a long multi-line prompt makes one giant bubble that pushes everything else off-screen. Collapse long prompts behind a disclosure.

Behavior:
- If a user prompt exceeds a threshold (e.g. > N lines or > M characters), render it collapsed: show the first few lines (or a one-line summary) with a "Show more"/disclosure affordance to expand, and "Show less" to re-collapse.
- Short prompts render as today (no disclosure).
- Keep it selectable/copyable when expanded (#95).
- Collapsed state is per-turn UI state (in-memory); default collapsed for long prompts.

Notes:
- Use DisclosureGroup or a custom expand/collapse with a line-limited Text + a toggle. Line-limit the collapsed view (e.g. .lineLimit(3)) and a gradient/"…" affordance.
- Applies to the user bubble specifically; assistant/plan/error already have their own structure (plan prose could reuse the same treatment later, out of scope here).
- Pick sensible thresholds; don't collapse a normal 1-2 line prompt.

Touch points: GeneratePanel TurnRow (.user branch) — likely a small CollapsibleText/expandable subview.

---

## 103: Refactor PhosphorSupport into multiple targets

+++
status: closed
priority: medium
kind: task
labels: architecture, effort:l
created: 2026-06-22T22:54:21Z
updated: 2026-06-23T00:42:48Z
closed: 2026-06-23T00:42:48Z
+++

Split the monolithic `PhosphorSupport` package into several focused targets, decoupling concerns and clarifying dependencies.

Current PhosphorSupport sub-areas: Audio, Compile, Generation, Model, Parser, Resources, Runtime, Source.

Proposed targets (to be refined):
- Generation — shader/material generation
- Model — core data model
- Runtime — rendering & runtime
- Parser/Compile — parsing & compilation
- (others as appropriate: Audio, Source, Resources)

Goal: clear target boundaries with explicit dependencies so e.g. the app doesn't pull in generation code unnecessarily.

- `2026-06-23T00:42:48Z`: Split the monolithic PhosphorSupport package into four focused targets and deleted the umbrella:

- PhosphorModel — core data model + BuiltinTextures resource (leaf, no Metal).
- PhosphorCompile — Parser + Compile + Source, owns Phosphor.h (-> Model; TOMLKit, tree-sitter).
- PhosphorRuntime — Runtime + Audio (-> Model, Compile; MetalSprockets, AVFoundation).
- PhosphorGeneration — Generation (-> Model, Compile; FoundationModelBackends).

PhosphorSupport is gone; the app imports the modules directly (no @_exported anywhere). Tests @testable-import the relevant module. Layering is clean: Model <- Compile <- {Runtime, Generation}. 76 tests pass, app builds with no warnings.

---

## 104: Support one-shot (init-time) passes

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-06-23T01:50:46Z
updated: 2026-06-23T06:05:14Z
+++

Add the ability to mark a pass as one-shot so it runs once at init/reset time rather than every frame.

Proposed approach:
- Add a `once: Bool` field to `Pass` (default false), parsed from front-matter.
- In `PhosphorPipeline`, encode one-shot passes only on the first frame after a compile/reload, and re-run them after `signalReset()` or a texture resize. Skip them on all other frames.
- Track 'has run since reset' state on the runtime; reset it on init, recompile, `signalReset()`, and texture reallocation.

Open questions:
- Exact re-run triggers (reset + resize + recompile?).
- Field naming (`once`).

---

## 105: Anthropic-level diagnostic logging of all model data

+++
status: closed
priority: low
kind: enhancement
labels: effort:m
created: 2026-06-23T03:32:38Z
updated: 2026-06-24T22:43:36Z
closed: 2026-06-24T22:43:36Z
+++

Add an opt-in, verbose diagnostic log that captures EVERYTHING exchanged with the language model, beyond the curated GenerationExchange/GenerationLog transcript. The goal is full transparency/debuggability of what the app sends and receives — the kind of complete request/response logging you'd want when filing a model-quality bug.

Capture, per model turn:
- Full system instructions verbatim (GeneratorInstructions, including the appended Phosphor.h interface), not truncated.
- The exact assembled request/prompt body (existing-shader block for modifies, bare prompt for fresh).
- All request parameters: model id/name, temperature/sampling, any decoding/Generable schema, max tokens, etc.
- The raw provider response. For @Generable/FoundationModels there is no raw token stream (decoded directly into GeneratedShader) — log the decoded structured value plus any provider metadata that IS available. For HTTP-backed providers, log the raw request/response bodies and headers (redacting secrets).
- Token usage / counts if the provider exposes them.
- Timing (startedAt, elapsed) and outcome (success/decoded result, or error).
- Retry chain: each compile/malformed retry with the error fed back.

Requirements:
- OFF by default; enable via a debug setting / env var. Verbose and potentially large.
- Redact API keys / secrets; never log Keychain material.
- Structured + greppable (e.g. JSONL to a file under Application Support, and/or os.Logger with a dedicated subsystem/category).
- Don't break or slow generation; logging is best-effort like GenerationLogStore.
- Consider a privacy note: prompts/source may be user-sensitive; keep local, document where it's written.

Touch points: ShaderGenerator, FoundationModelAdapter / provider adapters, GenerationExchange (already captures instructions/request/response/elapsed — extend or add a sibling raw log), a new verbose logger, Settings toggle.

Relates to #93 (per-turn trace popover surfaces a subset of this in the UI).

---

## 106: Support MTLBuffers including loading from file

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-06-23T03:54:56Z
updated: 2026-06-23T06:05:14Z
+++

Add support for MTLBuffer resources, including the ability to load buffer contents from a file.

---

## 107: Make a justfile to do the .aar encoding of examples

+++
status: closed
priority: medium
kind: none
created: 2026-06-23T16:03:33Z
updated: 2026-06-24T22:28:55Z
closed: 2026-06-24T22:28:55Z
+++

Add a justfile recipe to encode the examples (Examples/Examples.phosphord) into a .aar (Apple Archive) bundle, replacing the manual/zip process.

- `2026-06-24T22:28:55Z`: Added a justfile with an 'encode-examples' recipe that runs 'aa archive -d Examples/Examples.phosphord -o Phosphor/Examples.phosphord.aar' (LZFSE, root-relative — matches the SplashScene AppleArchive extractor). Regenerated the bundled .aar with the current shader set.

---

## 108: Use a real AI tool instead of faking it with Apple Intelligence

+++
status: closed
priority: medium
kind: none
created: 2026-06-23T16:03:48Z
updated: 2026-06-24T22:42:55Z
closed: 2026-06-24T22:42:55Z
+++

Shader generation currently goes through FoundationModelAdapter (Apple Intelligence) behind the LanguageModelPort protocol. Replace this with a real AI backend/tool rather than relying on the on-device Apple Intelligence model, which fakes/approximates the generation. Implement a LanguageModelPort conformance backed by a real model API.

- `2026-06-24T22:42:55Z`: Done. Conversational shader generation now runs through a real Anthropic/Claude backend (AnthropicProvider, Claude Opus) via API key or Claude-subscription OAuth — see ConversationProvider.make(). FoundationModels (Apple Intelligence) is no longer the conversational path; it's retained only as a one-shot fallback adapter.

---

## 109: Create PhosphorKit package with a reusable PhosphorView

+++
status: closed
priority: medium
kind: feature
labels: phosphorkit
created: 2026-06-23T20:01:21Z
updated: 2026-06-24T22:42:43Z
closed: 2026-06-24T22:42:43Z
+++

Extract a standalone `PhosphorKit` package exposing a high-level `PhosphorView` so other apps can drop phosphor shaders in with minimal effort.

Goal: a third-party app should be able to add a phosphor/CRT-style shader effect by adding the package and embedding `PhosphorView` (or applying it as a view modifier), without pulling in the full Phosphor editor app.

Open questions / scope:

- `2026-06-23T20:01:21Z`: API surface: `PhosphorView` as a standalone view vs. a `.phosphor()` SwiftUI modifier wrapping arbitrary content.
- `2026-06-23T20:01:21Z`: What's configurable (shader selection, uniforms/parameters, intensity) and sensible defaults.
- `2026-06-23T20:01:21Z`: Reuse the existing rendering core (MetalSprockets) from PhosphorSupport vs. a new lean dependency.
- `2026-06-23T20:01:21Z`: Package layout: new `Packages/PhosphorKit` alongside `PhosphorSupport`, or fold into it.
- `2026-06-23T20:01:21Z`: Example/demo target showing minimal integration.
- `2026-06-24T22:42:43Z`: Done. PhosphorKit now exists as a standalone Swift package (~/Projects/Current/PhosphorKit) vending PhosphorModel/PhosphorCompile/PhosphorRuntime, and exposes a high-level reusable PhosphorView (load a shader by name from a bundle, or render an in-memory source/parsed document). Reuses the existing MetalSprockets rendering core. The Phosphor app already consumes it (splash + About screens embed PhosphorView).

---

## 110: Support standalone .phosphor shader files

+++
status: closed
priority: low
kind: none
created: 2026-06-24T20:30:30Z
updated: 2026-06-24T20:33:10Z
closed: 2026-06-24T20:33:10Z
+++

Introduce a single-file '.phosphor' document type for a Phosphor shader (front-matter + Metal body), distinct from the existing multi-file '.phosphord' bundle and plain '.metal' source.

Motivation: PhosphorKit's PhosphorView(named:) currently guesses at a '.phosphor' extension when loading from a bundle, but no such file type actually exists. We want a real, first-class single-file format.

Scope:
- Define a 'io.schwa.phosphor' UTType (extension '.phosphor') in Info.plist, conforming to public.text / public.source-code as appropriate.
- Add a FileDocument (or extend PhosphorMetalDocument) that reads/writes '.phosphor' files.
- Register it in readableContentTypes and the New Document menu (PhosphorApp / SplashScene).
- Decide relationship to '.metal': is '.phosphor' just a renamed '.metal' with front-matter required, or a superset? Document the decision.
- Update PhosphorKit's PhosphorView loader once the canonical extension is settled.

Open questions:

- `2026-06-24T20:30:30Z`: One UTType or keep '.metal' and add '.phosphor' as an alias?
- `2026-06-24T20:30:30Z`: Should existing '.metal' docs be migratable/openable as '.phosphor'?
- `2026-06-24T20:33:10Z`: Implemented .phosphor as a first-class single-file UTType (io.schwa.phosphor.source, ext .phosphor), currently byte-identical to .metal. Added exported UTType + document type to Info.plist, registered in PhosphorMetalDocument readable/writable types, added 'New Phosphor Shader' menu item, and updated PhosphorKit's PhosphorView loader to prefer .phosphor over .metal. Migration of existing .metal docs deferred (not needed; both open in the same document).

---

## 111: Make .phosphor files JSON with front-matter and source as separate keys

+++
status: closed
priority: medium
kind: none
created: 2026-06-24T21:45:40Z
updated: 2026-06-24T22:15:42Z
closed: 2026-06-24T22:15:42Z
+++

Change the on-disk '.phosphor' format from a Metal source file with an embedded TOML front-matter comment (/* phosphor:environment ... */) to a JSON blob that breaks the configuration out from the shader source.

Proposed shape:
{
  "version": 1,
  "configuration": { ...the PhosphorConfiguration as JSON (output, passes, textures, uniforms)... },
  "source": "...the Metal kernel body, front-matter stripped..."
}

Motivation:
- The configuration is already Codable (PhosphorConfiguration: Codable) and is currently round-tripped as TOML inside a C-style comment. Storing it as first-class JSON removes the parse-the-comment dance and makes the config machine-editable/tooling-friendly.
- Keeping 'source' as its own key means the Metal body is clean (no front-matter), which is what the compiler/SourceAssembler already wants.

Scope / touch points:
- PhosphorKit:
  - PhosphorCompile/FrontMatter.swift: add a JSON document model + decode path. ParsedPhosphorSource currently assumes a single source string with an embedded block (PhosphorFrontMatter.parse / extractBlock). Either add a new entry point (e.g. ParsedPhosphorSource(jsonData:)) or a PhosphorDocument codable type.
  - PhosphorCompile/FrontMatterFormatter.swift: encodeBody/wrapFrontMatter/reformat assume the comment format; add JSON encode.
  - PhosphorRuntime/PhosphorView.swift loadSource(): currently reads raw text; needs to parse JSON for .phosphor (keep raw .metal path).
- Phosphor app:
  - PhosphorMetalDocument reader/writer (reads/writes UTF-8 text today) needs a JSON branch for the .phosphor UTType while keeping .metal as plain source.
  - Anything that calls ParsedPhosphorSource(source:) on .phosphor content.

Open questions:
- Versioning: include a 'version' field for forward-compat (suggested yes).
- Does '.metal' stay the embedded-TOML-comment format, with '.phosphor' becoming the JSON format? (i.e. the two extensions diverge — this supersedes the 'currently byte-identical' note from #110.)
- Migration: should the app auto-convert existing embedded-front-matter .phosphor files to JSON on open/save?
- Where does the canonical PhosphorDocument codable type live — PhosphorModel or PhosphorCompile?

Relates to #110 (which introduced .phosphor as a byte-identical alias of .metal).

- `2026-06-24T22:15:42Z`: Implemented. .phosphor is now a versioned JSON document (PhosphorDocument: version/configuration/source) in PhosphorKit. PhosphorMetalDocument reads/writes JSON for the .phosphor UTType (reassembling to embedded-front-matter text internally); .metal format unchanged. Bundled GenerationProgress.phosphor migrated to JSON. PhosphorView loader decodes .phosphor JSON, keeps .metal raw. Tests added in PhosphorKit.

---

## 112: Reorder inspector tabs: Generate first, Output last

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-24T22:46:24Z
updated: 2026-06-24T22:49:47Z
closed: 2026-06-24T22:49:47Z
+++

In the editor inspector (Phosphor/Views/PhosphorInspectorView.swift), the tabs are currently ordered Output (1), Configuration (2), Generate (3). Reorder so the Generate/chat tab is tab #1 and the Output ('info') tab is tab #3.

Target order: Generate (1), Configuration (2), Output (3).

Just reorder the Tab() entries in the TabView; the InspectorTab enum cases and selection logic don't need to change.

- `2026-06-24T22:49:47Z`: Reordered the inspector tabs to Generate (1), Configuration (2), Output (3).

---

## 113: Render Markdown in the generation conversation

+++
status: new
priority: medium
kind: enhancement
labels: effort:m, generation
created: 2026-06-24T22:51:04Z
+++

Assistant (and user) messages in the Generate panel transcript are rendered as plain text via SwiftUI Text (Phosphor/Views/GeneratePanel.swift, ConversationRow.content -> bubble, lines ~243-246 for .assistant, ~235-238 for .user). Claude's replies contain Markdown — bold, lists, inline code, fenced code blocks, links — which currently shows as raw markup.

Render Markdown instead:
- Assistant turns at minimum; ideally user turns too.
- Support inline styling (bold/italic/inline code/links) and block elements (paragraphs, bullet/numbered lists, fenced code blocks).
- SwiftUI Text supports a subset of Markdown via AttributedString(markdown:) but does NOT handle block elements (lists, code fences, headings). Decide between: (a) AttributedString for inline-only (cheap, misses code blocks), or (b) a fuller Markdown view (e.g. a small custom renderer, or a package) to get fenced code blocks — important since shader chat is code-heavy.
- Streaming: the assistant text grows token-by-token (lastItemContentLength drives autoscroll). Whatever renderer we use must handle partial/incomplete Markdown gracefully (a half-open code fence shouldn't break layout).
- Keep text selection working (.textSelection(.enabled) is applied today).

Open questions:
- Inline-only AttributedString vs a full block renderer — which is worth it?
- Add a dependency or hand-roll a minimal renderer?

---

## 114: Use HTML rendering for the conversation tab

+++
status: new
priority: low
kind: enhancement
labels: effort:l, generation
created: 2026-06-24T22:51:33Z
+++

Render the Generate panel transcript (Phosphor/Views/GeneratePanel.swift) using HTML — e.g. a WKWebView-backed view — instead of (or in addition to) SwiftUI Text. Assistant/user turns would be converted to HTML and displayed in a web view, giving full rich rendering: headings, lists, tables, fenced code blocks with syntax highlighting, links, etc.

Considerations:
- Likely convert Markdown -> HTML (Claude emits Markdown), then render in a web view. Overlaps with #113 (render Markdown) — this is the heavier 'full HTML/WebView' approach vs #113's lighter AttributedString path. Pick one direction.
- Streaming: assistant text grows token-by-token; the web view needs incremental/cheap updates without flicker or losing scroll position.
- Text selection, link handling (open externally), and theming (match app light/dark) need to work in the web view.
- Performance/overhead of a WKWebView per panel vs native SwiftUI rendering.
- Security: sanitize/sandbox the HTML; disable JS and remote loads if not needed.

Open questions:
- WKWebView vs a native Markdown renderer (#113) — decide and possibly close the other.
- Per-message web views vs one web view for the whole transcript.

---

## 115: Chat tab does not scroll to bottom when new content arrives

+++
status: new
priority: medium
kind: bug
created: 2026-06-24T23:21:22Z
+++

The Generate chat transcript (GeneratePanel.swift) still fails to scroll to the bottom when new content streams in. Existing onChange hooks on items.count, isGenerating, and lastItemContentLength call scrollToEnd, but the view stays pinned above the newest content. Likely the proxy.scrollTo fires before the freshly-appended/grown row is laid out in the List.

---

## 116: Add OpenAI as a model provider for shader generation

+++
status: closed
priority: medium
kind: feature
labels: effort:l, generation
created: 2026-06-24T23:41:37Z
updated: 2026-06-25T00:09:28Z
closed: 2026-06-25T00:09:28Z
+++

Implement OpenAI as a selectable generation backend alongside Anthropic. The Settings UI already has a Provider picker (ModelProvider enum in Phosphor/Views/SettingsView.swift) with OpenAI present but disabled ('coming soon'); make it real.

Scope:
- ModelProvider.openAI.isAvailable -> true once wired up.
- Add an OpenAI credentials section (API key field -> Keychain, with a link to the OpenAI API keys page). Mirror the Anthropic API-key section.
- Implement a LanguageModelPort/provider conformance backed by OpenAI (chat completions / responses API) with reliable tool calling for the agentic edit loop (see ConversationProvider / CollaborationKit's AnthropicProvider for the pattern).
- Route generation through the selected provider (phosphor.modelProvider AppStorage) instead of hardcoding Anthropic in ConversationProvider.make().
- Extend CredentialsModel.hasCredentials to consider the active provider's credentials.
- Model selection: which OpenAI model(s) to expose, default, max tokens.

Open questions:
- Does the conversational/agentic tool loop need a specific OpenAI model tier for reliable tool calls?
- Per-provider model picker, or just a sensible default per provider?
- OAuth/subscription equivalent, or API key only for OpenAI?

Relates to the provider-picker work and #108 (real AI backend).

- `2026-06-25T00:09:28Z`: Implemented. OpenAI is a selectable provider: Settings picker (Claude Subscription / Anthropic API / OpenAI) with an OpenAI API-key section, ConversationProvider.make() dispatches to OpenAIProvider (gpt-4o), CredentialsModel/hasCredentials honor the active backend, and the Generate panel shows the active provider. Known follow-up: gpt-4o parallel tool calls can issue blind edits in the agentic loop — tracked upstream in CollaborationKit#12 (disable parallel_tool_calls).

---

## 117: Flesh out in-app Help

+++
status: new
priority: low
kind: documentation
labels: effort:m
created: 2026-06-25T00:52:46Z
+++

The Help menu now opens a minimal Help window (Phosphor/Views/HelpScene.swift) with a one-line description and two links (Apple Metal site + MSL spec PDF). Replace this stub with real help content.

Ideas:
- Getting started: open/create a shader, the live preview, play/pause/reset.
- The Phosphor kernel model: kernel signature, Uniforms/UserUniforms, writing to the output texture, the front-matter (textures/passes/uniforms).
- Multi-pass + ping-pong feedback.
- User uniforms and the live uniforms panel.
- AI generation: providers (Claude subscription / Anthropic API / OpenAI), model picker, the chat/edit loop.
- Bundles (.phosphord) vs single-file (.metal/.phosphor).
- Keyboard shortcuts (View + Render menus).
- Links: Apple Metal site, MSL spec PDF, the Phosphor.h prelude.

Consider whether this should be DocC/HTML rendered in-app vs native SwiftUI pages, and whether it overlaps with #25 (DocC + README).

---

## 118: Video input: video file source

+++
status: new
priority: medium
kind: feature
labels: effort:l
created: 2026-06-25T03:01:17Z
updated: 2026-06-25T03:03:31Z
+++

Allow a video file (mp4/mov/etc.) to be used as a texture input channel, sampled per-frame in sync with the shader timeline.

## Motivation
Complements the webcam source (#39). Many Shadertoy-style effects process video; a file source gives reproducible, scrubbable input.

## Scope
- Pick a video file as a channel input (drag & drop / file picker, mirroring image asset handling #65).
- Decode frames (AVFoundation / AVPlayerItemVideoOutput) and upload to a Metal texture each render frame.
- Map shader time to video playback time; loop when the clip ends.
- Pixel format conversion to the channel's texture format (#68).

## Open questions (needs-info)
- Playback follows shader clock, or real-time + sample latest frame?
- Audio track: ignore, or feed into the audio input path?
- Persistence: embedded vs. referenced file in a bundle?

Related: #39 (webcam), #65 (image assets), #68 (pixel formats).

- `2026-06-25T03:03:35Z`: Effort: L. The main cost is introducing the first *live/streaming texture* pathway — image inputs today load once at materialization; video needs a per-frame upload hook in the runtime plus a model-level live-texture source case. This infra is shared with #39 (webcam); whoever does one should build the shared live-texture plumbing for both. If #39 lands first, this drops to Medium.

---

## 119: Export rendered frame as screenshot

+++
status: new
priority: medium
kind: feature
created: 2026-06-25T03:01:23Z
+++

Export the current rendered frame to an image file (PNG/JPEG/TIFF).

## Scope
- Capture the displayed output texture for the current frame.
- Save to disk via a save panel; default to PNG.
- Respect the configured output resolution / pixel format (#68).
- Optional: copy-to-clipboard variant.

## Open questions (needs-info)
- Capture at drawable resolution or at a user-specified export resolution?
- Include/exclude any UI overlay (assume just the shader output).

Related: #68 (pixel formats).

---

## 120: Export rendered output as video

+++
status: new
priority: medium
kind: feature
created: 2026-06-25T03:01:29Z
+++

Render the shader over a time range and encode the frames to a video file (mp4/mov).

## Scope
- Offline/render-to-texture loop driven by a fixed timeline (start/end time, fps), independent of real-time display rate.
- Encode frames via AVAssetWriter (H.264/HEVC), with configurable resolution and frame rate.
- Progress UI + cancel.
- Deterministic frame timing so exports are reproducible.

## Open questions (needs-info)
- Capture real-time playback, or render offline at a fixed fps for determinism (prefer offline)?
- Include audio in the export (when audio input / file sources exist)?
- Default resolution: drawable size vs. configured output vs. user choice?

Related: #119 (screenshot export), #68 (pixel formats).

---

## 121: Remove MetalSprockets dependency from PhosphorKit

+++
status: new
priority: medium
kind: task
created: 2026-06-25T03:02:12Z
updated: 2026-06-25T17:02:09Z
+++

Make PhosphorKit dependency-free of MetalSprockets / MetalSprocketsAddOns by replacing the MetalSprockets-based render layer in PhosphorRuntime with raw Metal.

Design and full breakdown: see RFCs/RFC-004-remove-metalsprockets.md

Acceptance:
- Package.swift has no MetalSprockets dependencies or products.
- PhosphorRuntime renders identically (ping-pong parity, audio buffers, flipY).
- Tests pass (excluding the known pre-existing Voxels failure).

Effort: XL.

---

## 122: Make .phosphor documents self-contained: embed images and other assets

+++
status: new
priority: medium
kind: feature
created: 2026-06-25T03:04:10Z
+++

Today a `.phosphor` file is a single JSON blob (`PhosphorDocument`: version + configuration + source). Image inputs (`TextureInit.image(file:)`) are resolved through a *host-injected asset registry* — the asset bytes live outside the document. That means a `.phosphor` isn't portable: open it elsewhere and the referenced images are missing.

## Goal
Let a `.phosphor` document carry its own assets (images, and later video/audio/etc.) so a single file is self-contained and shareable.

## Approaches (needs-info / decision)
1. **Bundle the document** — make `.phosphor` (or lean on the existing `.phosphord` bundle) a FileWrapper directory: `document.json` + an `Assets/` folder. Cleanest for large binary assets; no base64 bloat.
2. **Embed in JSON** — add an `assets` map to `PhosphorDocument` (filename → base64 data + UTType). Keeps single-file simplicity; bloats JSON and is wasteful for video.

(Relationship between `.phosphor` flat file and `.phosphord` bundle is the subject of #78 — coordinate.)

## Scope
- Decide single-file-with-embedded vs. bundle (see #78).
- Extend `PhosphorDocument` (or the bundle format) to store named assets + their type.
- Replace/augment the host-injected asset registry so the document's own assets are the source of truth (host registry becomes a fallback / built-ins only).
- Read/write path: encode assets on save, materialize them on load and feed the runtime's asset lookup.
- Bump `PhosphorDocument.currentVersion` + migration for v1 docs.

## Open questions (needs-info)
- Embed-in-JSON vs. bundle directory? (ties into #78)
- Which asset kinds beyond images now — just images, or also video (#118) / audio?
- Dedup identical assets; cap embedded size?

Related: #78 (flat vs. bundle decision), #65 (image assets), #118 (video file source).

- `2026-06-25T03:04:40Z`: Third option: don't embed at all — **reference** external assets via persistent links.

- Store a stable reference per asset instead of bytes: a file URL plus a **security-scoped bookmark** (sandbox-safe) so the app can re-resolve and `startAccessingSecurityScopedResource()` on load.
- Pro: tiny documents; no base64 bloat; works for large video. Con: not portable/self-contained — moving/deleting the original breaks the doc (need stale-bookmark handling + a 'relink' UI).

So the format should probably support a per-asset choice: **embedded** (portable) vs. **referenced** (bookmark). Could default to referenced for large/video assets and embedded for small images. Bookmarks must be created in the sandboxed app layer (PhosphorKit stays platform-y but bookmark creation/resolution lives app-side or behind an injected resolver).

---

## 123: Add more built-in textures, including 1D colour-palette LUTs

+++
status: new
priority: low
kind: feature
created: 2026-06-25T03:25:12Z
+++

Expand `BuiltinTextures.all` beyond the current set (mandrill, testcard, several noise variants). In particular, ship 1D colour-palette / gradient LUTs that shaders can index by a scalar to colourise output — a very common shadertoy idiom.

## Palette ideas
- Classic scientific/perceptual maps: viridis, magma, inferno, plasma, turbo, cividis.
- Classic/aesthetic: jet (for nostalgia), rainbow/hsv, grayscale, heat, cool/warm.
- A few hand-tuned artistic gradients (sunset, neon, fire).

## Dimensionality decision (needs-info)
The runtime currently hard-codes `texture2d` for all bindings (`PhosphorHeader.swift`), and `TextureInit`/sizing has no 1D concept. Two ways to ship palettes:
1. **Nx1 2D textures** — zero model/header changes; sample with `uv.x`, y=0.5. Easiest; ship as PNGs in `Resources/BuiltinTextures`. Recommended first cut.
2. **True `texture1d`** — needs a binding/header dimensionality option and runtime support. More correct/ergonomic but larger change.

## Scope (option 1, recommended)
- Generate palette PNGs (e.g. 256x1) and add entries to `BuiltinTextures.all` with display names.
- Maybe a `builtin:palette/...` sub-namespace, or just `builtin:viridis` etc.
- Document usage (sample a builtin palette by a scalar) in README / starter content.

## Open questions
- Nx1 2D now vs. add true 1D texture support (separate issue)?
- Which palettes to ship (avoid bloat — pick ~6–8)?
- License: viridis/magma/etc. are CC0/MIT-friendly; jet/turbo from Google (Apache) — verify before bundling.

Related: #65 (image assets).

- `2026-06-25T03:27:30Z`: Decision: ship palettes as **Nx1 2D textures** (e.g. 256x1). No model/header changes needed — sample with uv.x at y=0.5. True `texture1d` support is out of scope here; can be a separate issue later if ergonomics warrant it.

---

## 124: Document objectWillChange shim for @Observable + ReferenceFileDocument

+++
status: new
priority: low
kind: none
created: 2026-06-25T16:50:10Z
+++

On the OS 26 backport, PhosphorMetalDocument and PhosphorBundleDocument are @Observable classes that must also conform to ReferenceFileDocument, which refines ObservableObject. The @Observable macro does not synthesize objectWillChange, and the ObservableObject default synthesis does not fire, so both documents declare an explicit '@ObservationIgnored let objectWillChange = ObservableObjectPublisher()' purely to satisfy the protocol. SwiftUI observes via Observation/@Bindable, not this publisher.

Risk: not yet runtime-tested on 26. Verify save / open / Save As / undo-redo behave correctly. If the dual ObservableObject + @Observable conformance causes change-tracking glitches, revisit (e.g. drop @Observable in favor of @Published, or wrap the document).

---

## 125: New document doesn't refresh Recent Documents in Splash

+++
status: new
priority: low
kind: none
created: 2026-06-25T16:51:21Z
+++

Creating a new document (Cmd-N / Cmd-Shift-N, or via the splash) does not update the Recent Documents list shown in the Splash window. SplashScene reads NSDocumentController.shared.recentDocumentURLs as a plain computed property, so the view doesn't re-render when the recents list changes. Need to observe recent-document changes (e.g. NSDocumentController KVO on recentDocumentURLs, or a refresh trigger when the splash reappears) so the list stays current.

---

## 126: Custom document icons not showing for .phosphor files

+++
status: new
priority: low
kind: none
created: 2026-06-25T16:54:21Z
+++

Finder/the OS isn't showing a custom document icon for .phosphor files. Likely causes:

1. No icon is declared at all: neither the CFBundleDocumentTypes entry nor the UTExportedTypeDeclarations for io.schwa.phosphor.source specifies an icon (no CFBundleTypeIconFile / UTTypeIconFile / icon asset). There is no document-icon asset in the bundle.

2. UTI resolution: io.schwa.phosphor.source conforms to public.source-code + public.utf8-plain-text, but .phosphor content is actually JSON. The OS may be resolving the extension/content to a generic JSON/text type and using that system icon instead of ours.

To fix: add a document icon asset (iconset / .icon) and wire it via CFBundleTypeIconFile (or UTTypeIconFile on the exported type), and double-check the UTI declaration so .phosphor maps unambiguously to io.schwa.phosphor.source rather than a built-in JSON/plain-text type. Verify .phosphord (bundle) icon too.

---

## 127: Export: convert .phosphor shader to a SwiftUI Shader effect (zero-dep)

+++
status: new
priority: low
kind: none
created: 2026-06-25T17:25:00Z
+++

A distinct, optional export path (separate from the PhosphorKit embed-and-link core): transpile a .phosphor shader into a SwiftUI Shader effect with ZERO dependencies — not even PhosphorKit.

Shape:
- Emit a .metal [[stitchable]] function plus a SwiftUI ShaderLibrary / colorEffect / layerEffect call site.
- Consumer needs no PhosphorKit, no MetalSprockets — just the generated .metal + a few lines of SwiftUI.

Cost / limitations (this is a lossy transpile, only viable for the subset of shaders that fit SwiftUI's Shader model):
- Single-pass only (no multipass / ping-pong).
- Kernel must be rewritten from a compute kernel to a stitchable function.
- Much less control over textures and uniforms.
- No audio buffers.

Open question: is this worth doing at all? Park as a maybe. It does NOT block the core embed-and-link work (PhosphorKit / PhosphorKitLite) or RFC-004's successor.

---

## 128: Export as Swift Package (template archive + file swap)

+++
status: closed
priority: medium
kind: none
created: 2026-06-25T19:32:41Z
updated: 2026-06-25T20:01:58Z
closed: 2026-06-25T20:01:58Z
+++

Add an "Export as Swift Package" action that emits a standalone, buildable Swift package wrapping the current shader — dogfooding the real integration contract (embed .phosphor + link PhosphorKit + PhosphorView(named:)), unlike the lossy SwiftUI Shader transpile (#127).

Mechanism:
1. Template package (authored in-repo, verified to build + preview):
   - Package.swift depends on PhosphorKit pinned to tag 0.1.0
     (https://github.com/schwa/PhosphorKit).
   - Embeds a .phosphor resource (fixed name, e.g. Shader.phosphor).
   - A #Preview { PhosphorView(named: "Shader") }.
2. Archive the template as an .aar (AppleArchive) and ship it as a bundled app
   resource — reuse the existing archive expand plumbing (SplashView already
   reads Examples.phosphord.aar via ArchiveByteStream).
3. Export button in the app: pick a destination, expand the archive there, then
   swap the single bundled .phosphor file for the current document's source.
   No renaming for now (keep the resource name + PhosphorView(named:) fixed).

Scope decisions (this pass):
- Reuse the existing AppleArchive expand code.
- Pin PhosphorKit to tag 0.1.0.
- Swap the single .phosphor file only; no package/preview/name rewriting.

Follow-ups (separate): rename package + preview + named: to the document's name;
offer export-as-Xcode-project / Playground variants; build-time .metallib
precompile so the exported package doesn't compile the shader at runtime.

- `2026-06-25T20:01:58Z`: Implemented: template package (Templates/PhosphorShaderPackage) + just encode-template archives a clean copy to Phosphor/Resources/PhosphorShaderPackage.aar; File > Export as Swift Package expands it and swaps in the current document's .phosphor.

---
