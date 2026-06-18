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
status: open
priority: medium
kind: bug
labels: effort:s
created: 2026-06-18T20:05:43Z
updated: 2026-06-18T22:06:31Z
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
status: open
priority: medium
kind: feature
labels: effort:s
created: 2026-06-18T21:43:30Z
updated: 2026-06-18T22:06:31Z
+++

The kernel sees `uniforms.mouse` (xy in pixels), `uniforms.mouseButtons` (bitmask), and `uniforms.mouseClickOrigin` (xy of last press). These are declared in the BuiltinUniforms struct and wired all the way through to the shader, but the host never assigns them — they are always zero.

To make them work:
- Add SwiftUI gestures to the PhosphorView preview (DragGesture for press-and-drag, onContinuousHover for hover, an NSEvent monitor on macOS for right/middle/scroll if we want them).
- Store the live mouse position, button mask, and click-origin in PhosphorView's @State.
- Plumb them into BuiltinUniforms when building the per-frame uniforms.
- Consider whether the values should be in pixels (matching uniforms.resolution) or normalized 0..1; pixels match the existing field semantics.
- The fade demo would be a good test: scrub the mouse around and see the column follow it.

Shadertoy semantics for reference: iMouse.xy is the current position while held, iMouse.zw is the click origin with sign indicating button state. We chose to split this into 3 separate fields for clarity; preserve those semantics.

---

## 13: Add a 'New Shader From Prompt…' preset menu

+++
status: open
priority: low
kind: feature
labels: effort:s
created: 2026-06-18T21:45:48Z
updated: 2026-06-18T22:06:31Z
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
status: open
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-18T21:49:10Z
updated: 2026-06-18T22:06:31Z
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
- Single short comment vs. structured doc block? Probably let the model choose, but show one structured example in the system prompt.
- Should multi-pass shaders document each kernel separately? Yes \u2014 they're often quite different.
- Trade-off: more comments = more output tokens = slower + costlier generation. Probably worth it.

---

## 16: Port Phosphor 1 example snippets into Examples/

+++
status: open
priority: medium
kind: task
labels: effort:l
created: 2026-06-18T21:52:41Z
updated: 2026-06-18T22:06:31Z
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

---

## 17: Microphone audio input as a shader resource

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-06-18T21:52:56Z
updated: 2026-06-18T22:06:31Z
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
status: open
priority: low
kind: enhancement
labels: effort:s
created: 2026-06-18T21:54:20Z
updated: 2026-06-18T22:06:31Z
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

---

## 20: Move uniforms-panel toggle into the toolbar

+++
status: open
priority: low
kind: enhancement
labels: effort:xs
created: 2026-06-18T21:57:15Z
updated: 2026-06-18T22:06:31Z
+++

Today the uniforms panel (top-right overlay on the preview) has its own little switch toggle in its header. Move that toggle into the document window's main toolbar so it's discoverable next to Generate and Phosphor.h.

Implementation:
- PhosphorView currently owns @State showUniformsPanel: Bool. Pull it up to PhosphorDocumentView (or expose a binding) so the toolbar can drive it.
- Add a ToolbarItem with a slider/sparkles/control-style icon \u2014 maybe slider.horizontal.3 \u2014 wired to that binding.
- Remove the inline switch from the uniforms-panel header (the header still shows the 'Uniforms' label).
- Disable the toolbar toggle when the current document has no uniforms declared, so it's not a dead control on those shaders.
- Persist across documents via @AppStorage so muscle memory carries between windows.

---

## 21: Generated shaders are often upside down — teach the model our coordinate system

+++
status: open
priority: medium
kind: bug
labels: effort:xs
created: 2026-06-18T22:04:00Z
updated: 2026-06-18T22:06:31Z
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
