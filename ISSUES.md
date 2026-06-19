# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Step 5: TextureInit.image — load CGImage assets into ping-pong textures

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-06-18T20:01:51Z
updated: 2026-06-18T22:06:31Z
+++

The asset-resolution path is wired up to the runtime (host injects `[String: PhosphorAsset]` into `PhosphorView`), but the materializer doesn't yet honor `TextureInit.image(name:)` — all textures start zero-filled.

Implementation:
- Plumb `assets: [String: PhosphorAsset]` through `PhosphorView -> PhosphorRuntime`.
- In `PhosphorRuntime.allocate`, after creating an MTLTexture, if `spec.initial == .image(name)`, look up the asset, upload the CGImage's bytes to the texture (via an MTLBlit or MTKTextureLoader).
- For ping-pong resources: copy the same initial contents into both halves of the pair.
- Add a test that loads a tiny known-color CGImage and verifies the first frame's iChannel0 sample matches.

Diagnostic case to handle: missing name -> emit a non-fatal `PhosphorDiagnostic` and zero-init the texture.

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
status: open
priority: low
kind: feature
labels: effort:xl
created: 2026-06-18T20:03:03Z
updated: 2026-06-18T22:06:31Z
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
status: open
priority: medium
kind: bug
labels: effort:m
created: 2026-06-18T20:05:56Z
updated: 2026-06-18T22:06:31Z
+++

Reported: while the Game of Life demo runs, app memory usage grows continuously (no plateau). Needs investigation — could be leak, could be expected (caches), could be observation-system retention.

Suspects, in rough likelihood order:
1. Per-frame MTLBuffer allocations in `PhosphorRuntime.writeBuiltinUniforms` are released (no retain in our code) but Metal's allocator may pool them. Run with leaks(1) / malloc-stack-logging / Instruments "Allocations" to confirm whether actual leaks vs allocator caching.
2. `@Observable PhosphorRuntime` mutating its dictionaries each frame may cause observation-registration churn. Worth checking under Instruments.
3. The shader runtime-compiled `MTLLibrary` and `MTLComputePipelineState` are recreated every time we `update(environment:source:)` — should only fire on env/source change, but verify with a counter.
4. GPU residency tracker / Metal logging buffer if MS_METAL_LOGGING=1 is on — known to grow.

Action: profile under Instruments Allocations + Leaks for ~60 sec of steady-state GoL playback, attribute growth to a category, then fix or close as expected.

---

## 10: Colorise TOML in front matter too

+++
status: open
priority: medium
kind: enhancement
labels: effort:s
created: 2026-06-18T20:45:57Z
updated: 2026-06-18T22:06:31Z
+++

Currently TOML syntax highlighting isn't applied to front matter blocks. Extend colorisation to TOML in front matter.

---

## 11: Picker to show ANY in-use texture instead of just output texture

+++
status: open
priority: medium
kind: enhancement
labels: effort:m
created: 2026-06-18T21:32:32Z
updated: 2026-06-18T22:06:31Z
+++

Add a picker UI to select and display any texture currently in use, not just the output texture.

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
status: open
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-18T21:46:29Z
updated: 2026-06-18T22:06:31Z
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
status: open
priority: low
kind: task
labels: effort:m
created: 2026-06-18T22:05:23Z
updated: 2026-06-18T22:06:31Z
+++

Sweep the SwiftUI surface (PhosphorView, PhosphorDocumentView, GeneratePanel, SettingsView, MetalSourceView, UniformControl) for:

- Idiomatic API use (binding shapes, @Bindable vs @Observable, @State macro patterns).
- Accessibility: VoiceOver labels/hints/traits, Dynamic Type, keyboard nav, focus order.
- Layout robustness: small windows, large fonts, RTL.
- Perf: unnecessary view recomputes, large @State that triggers heavy redraws (the uniforms dict, the AttributedString in MetalSourceView), per-frame work in body.
- 2027-era APIs: anything we should adopt (NavigationSplitView for the doc layout? Inspector? scenePadding? toolbar visibility APIs?).

Use the swiftui-specialist and accessibility-audit skills.

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
status: open
priority: low
kind: task
labels: effort:s
created: 2026-06-18T22:05:43Z
updated: 2026-06-18T22:06:31Z
+++

Add a .swiftlint.yml (if not present) and run `swiftlint lint --quiet` over the package + app. Fix violations or document opt-outs.

Particular things likely to come up:
- Force unwrap (`Demo.all.first!` style \u2014 we have one).
- Cyclomatic complexity in the long switches in UniformControl / UniformValue.
- Long files (PhosphorRuntime.swift is getting chunky).
- Type body length / function body length.
- Trailing whitespace / vertical_whitespace.

Use the swift-linting skill.

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
status: new
priority: medium
kind: none
created: 2026-06-18T22:08:22Z
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
status: new
priority: medium
kind: none
created: 2026-06-18T22:08:49Z
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
status: new
priority: medium
kind: enhancement
created: 2026-06-18T22:15:45Z
+++

Adopt the Metal style where the grid/thread index is declared as a global variable (e.g. via attribute on a global) rather than passed as a parameter to the kernel function.

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
status: new
priority: low
kind: enhancement
created: 2026-06-19T01:04:30Z
+++

Current TOML generation produces rather verbose output. Investigate ways to coax tomlkit into emitting a more compact representation (e.g. inline tables, inline arrays, fewer blank lines, compact dict styling) where appropriate.

---

## 39: Video input: webcam source

+++
status: new
priority: medium
kind: feature
created: 2026-06-19T01:23:57Z
+++

Add support for using a webcam as a live video input source.

---
