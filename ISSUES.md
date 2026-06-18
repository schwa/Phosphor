# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Step 5: TextureInit.image — load CGImage assets into ping-pong textures

+++
status: new
priority: medium
kind: none
created: 2026-06-18T20:01:51Z
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
status: new
priority: medium
kind: none
created: 2026-06-18T20:02:05Z
+++

The data model already defines `UniformDecl`, `UniformKind`, `UniformValue`, `UniformUIHint`. The header builder emits a `struct UserUniforms` typedef. But the values never flow:

1. The host UI doesn't render any controls.
2. The runtime's userUniformsBuffer is sized but never written.
3. `UniformValue`s declared in the env never reach the GPU.

Implementation:
- Define a wire layout for `UserUniforms` matching the auto-generated MSL struct, including correct MSL padding for float3/float4. `PhosphorHeader` emits the typedef; the runtime mirrors that layout in a Swift function that packs an ordered `[UniformDecl]` + values dict into the buffer.
- Host UI: `PhosphorView` exposes a `@Binding values: [String: UniformValue]` (or owns its own `@State` keyed by name with defaults from the env). For each `UniformDecl`, render the right SwiftUI control by `UniformUIHint` (`Slider`, `ColorPicker`, `Toggle`, vector field).
- `PhosphorRuntime.writeUserUniforms` packs values + memcpys into a fresh `MTLBuffer` each frame (same per-frame-alloc dodge as built-in Uniforms; cross-reference the latent race issue).
- Test that round-trips a small uniform set through the GPU and reads back via a single-pixel render.

---

## 3: Step 7: TOML front-matter parser

+++
status: new
priority: high
kind: none
created: 2026-06-18T20:02:15Z
+++

The whole "data-driven" promise relies on this: a single `.metal` string carries its own environment in a `/* phosphor:environment ... */` block at the top of the file. Today `PhosphorEnvironment` is built only from Swift literals.

Implementation:
- Pick a Swift TOML library (`TOMLKit` is the strongest candidate — pure Swift, Decodable, actively maintained).
- Parser: `func parsePhosphorSource(_ source: String) -> (PhosphorEnvironment?, [PhosphorDiagnostic])`.
- Strip the fenced TOML block from the top of the source (we already have `SourceAssembler.stripFrontMatter`).
- Decode the TOML body into `PhosphorEnvironment` via Decodable. The current `Codable` impls should mostly Just Work; verify the inline-table / array-of-tables shape from the design doc round-trips.
- Wire it into `PhosphorView`: if env is nil, infer from `source`; otherwise honor the explicit env argument. Probably split into a `PhosphorView(source:)` convenience that parses, and a `PhosphorView(environment:, source:)` raw form.
- Add the docs example from §4 of Phosphor2.md as a test fixture; verify the resulting env equals the equivalent Swift literal.

---

## 4: Step 8: FlipTiming.immediate — within-frame flip semantics

+++
status: new
priority: low
kind: none
created: 2026-06-18T20:02:28Z
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
status: new
priority: low
kind: none
created: 2026-06-18T20:02:41Z
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

---

## 6: Latent race: Uniforms / UserUniforms MTLBuffer rewritten while GPU reads previous frame

+++
status: new
priority: low
kind: none
created: 2026-06-18T20:02:53Z
+++

`PhosphorRuntime.writeBuiltinUniforms` currently allocates a fresh `MTLBuffer` per frame for the built-in uniforms — correct, but wasteful (one MTLBuffer alloc per frame). When user uniforms get wired up (#2), the same pattern will apply.

The original implementation reused a single `MTLBuffer` and memcpy'd into it each frame. That caused intermittent GPU page faults around frame 60 — the previous frame's GPU work was still reading the buffer when the CPU wrote frame N+1's values into it. The per-frame allocation works around this safely but at allocator cost.

Right answer: triple-buffer with a frame index that advances per frame, write into the slot that's not in flight. Standard Metal idiom; mirrors how the framework itself handles per-frame state.

Affects:
- `PhosphorRuntime.uniformsBuffer` (today)
- `PhosphorRuntime.userUniformsBuffer` (after #2)
- Possibly the channel argument buffers if #5 forces per-frame rebuild.

---

## 7: Stretch: in-app editor UI for environment metadata

+++
status: new
priority: low
kind: none
created: 2026-06-18T20:03:03Z
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
status: new
priority: medium
kind: none
created: 2026-06-18T20:05:43Z
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
status: new
priority: medium
kind: none
created: 2026-06-18T20:05:56Z
+++

Reported: while the Game of Life demo runs, app memory usage grows continuously (no plateau). Needs investigation — could be leak, could be expected (caches), could be observation-system retention.

Suspects, in rough likelihood order:
1. Per-frame MTLBuffer allocations in `PhosphorRuntime.writeBuiltinUniforms` are released (no retain in our code) but Metal's allocator may pool them. Run with leaks(1) / malloc-stack-logging / Instruments "Allocations" to confirm whether actual leaks vs allocator caching.
2. `@Observable PhosphorRuntime` mutating its dictionaries each frame may cause observation-registration churn. Worth checking under Instruments.
3. The shader runtime-compiled `MTLLibrary` and `MTLComputePipelineState` are recreated every time we `update(environment:source:)` — should only fire on env/source change, but verify with a counter.
4. GPU residency tracker / Metal logging buffer if MS_METAL_LOGGING=1 is on — known to grow.

Action: profile under Instruments Allocations + Leaks for ~60 sec of steady-state GoL playback, attribute growth to a category, then fix or close as expected.

---
