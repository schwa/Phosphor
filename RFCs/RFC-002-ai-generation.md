# RFC-002: AI Shader Generation — Current State and Direction

Status: Draft
Date: 2026-06-22
Related issues: #48, #74, #82 (done), #83, #87 (done), #89 (done), #91

## Summary

Phosphor turns natural-language prompts into runnable Metal compute shaders. This
RFC documents how AI generation works **today**, then lays out where it's
**going** based on the issues we've filed. The throughline: move from a
one-shot, text-only "prompt in, source out" tool to an iterative, multi-modal,
plan-driven assistant that understands the document's full context (helpers,
built-in textures, the rendered result) and lets the user steer.

## Current State

### Architecture (ports & adapters)

Generation is structured as ports & adapters (#44), so the flow logic is testable
without a network or a device.

- **`ShaderGenerator`** owns the *flow*: prompt assembly, the compile-and-retry
  loop, and empty-body checks. It depends only on a `LanguageModelPort`.
- **`LanguageModelPort`** is the one seam: `respond(to:) async throws ->
  GeneratedShader`. One call == one model turn. Conformers keep a session so the
  model retains conversation history across the retry turn.
- **`FoundationModelAdapter`** is the production port, backed by Apple's
  `FoundationModels` (`LanguageModelSession`). Three backends: on-device
  (`SystemLanguageModel`), Private Cloud Compute, and Anthropic (key from the
  Keychain). Tests use a fake port that returns scripted `GeneratedShader`s.

### The generation flow

1. The user types a prompt in the **Generate** inspector tab (chat UI, #82) and
   picks a model.
2. `ShaderGenerator.generate(prompt:existingSource:)`:
   - Extracts prior prompts from the source (`PromptHistory.extract`) so a
     modify request appends rather than overwrites.
   - Builds the prompt: a fresh request passes the prompt through; a modify
     request wraps the existing source in an `EXISTING SHADER` block.
   - Sends one turn through the port; decodes a `GeneratedShader`.
   - **Compile check**: assembles + compiles the result. On failure, one
     automatic retry feeding the Metal compiler errors back to the model.
   - Returns a `GenerationResult` (source + model-provided title).
3. The new source replaces the document text through the undoable `TextMutator`
   path (#76), so generation is a single undo step.

### What the model is told (`GeneratorInstructions`)

A system-prompt set sized per backend (compact for the small on-device context,
full for cloud/Anthropic). It covers: the exact kernel signature, the `Uniforms`
/ `UserUniforms` / `textures` contract, the coordinate system (Y=0 at top),
feedback/ping-pong rules, the state-vs-display separation pitfall, and MSL-vs-GLSL
strictness. Plus, recently:

- **Available helpers (#87):** the full-context instructions append
  `PhosphorInterface.source` — a declarations-only view of `Phosphor.h` derived
  at runtime via tree-sitter (function bodies stripped, signatures + constants
  kept). The model learns what's in scope (rotate2D/3D, hsv, snoise2D/3D/4D,
  valueNoise3D, fbm3D, …) without being shown the implementations, and is told
  not to re-define them or `#include` anything. This can never drift from the
  real header.
- **Built-in textures (#89):** `GeneratedResource` carries an optional
  `imageFile`; the instructions list the reserved built-in names
  (`builtin:mandrill`, `builtin:testcard`, the noise set) so the model can seed a
  texture with an image and sample it.

### The schema (`GeneratedShader`)

A `@Generable` struct is the model-visible contract: `title`, `body` (MSL),
`resources` (id/format/pingPong/imageFile), `passes` (id/output/inputs),
`uniforms` (name/kind/default/slider range), `outputResourceID`, `flipY`. A host
adapter (`toPhosphorConfiguration()`) maps this to the runtime model, synthesizing
the per-binding access list (write for the output, read for each input, distinct
`<id>Prev` field for self-feedback). The generation schema is deliberately
simpler than the runtime model; the adapter bridges them.

### UI (today)

Non-modal **Generate** tab in the inspector (#81): a scrollable chat transcript
(user prompts + assistant turns with title and elapsed time) over a bottom-pinned
composer (prompt field + model picker + Generate/Modify). Status during a run
distinguishes fresh vs. modify (with source byte count) and surfaces the live
compiler errors on retry. Prior prompts re-hydrate from the source on open.
Transcript is in-memory for the session.

### Current limitations

- **Text-only.** No signal about how the output *looks* once rendered.
- **One-shot intent.** Vague prompts and pasted source force the model to guess
  structure, front-matter, and intent all at once.
- **No durable history.** The chat transcript and prior versions don't survive
  reopen (only the embedded `/* prompt: */` comments do).
- **Single retry, compile-only.** The only feedback signal is "did it compile."

## Direction

The filed issues form a coherent arc. Grouped by theme:

### 1. Richer context into the model

- **#87 (done):** helper interface. — *shipped.*
- **#89 (done):** built-in textures the model can reference. — *shipped.*
- **#88 (done):** `Phosphor.h` on disk as the single source of truth feeding
  both the runtime and the interface. — *shipped.*

These establish the pattern: **one source of truth, surfaced to the model as a
clean interface.** Future context (e.g. a 3D-texture sampling API, #92) plugs in
the same way.

### 2. Multi-modal feedback (#48)

Close the visual loop: attach the current rendered frame (a PNG snapshot of the
live preview) to the generation request so vision-capable backends (Claude;
maybe PCC) can steer toward what's on screen. v1: a "Use current frame" toggle in
the composer; gate it off for backends without vision. The image complements the
prompt; it doesn't replace it. This is the single biggest quality lever after
context — it turns "compile-only" feedback into "looks-correct" feedback.

Longer term (out of #48's v1): generator-initiated "render N frames, diff against
a target, iterate" loops.

### 3. Plan-then-generate (#74)

Insert a **planning stage** before code generation. A first model turn (seeded by
heuristics that detect Shadertoy/feedback shapes) returns a *structured plan* —
intent, shape (single-pass / multi-pass / feedback), resource/uniform/pass layout,
GLSL→MSL mapping when porting, and open decisions surfaced to the user — rather
than code. The user reviews/edits the plan, then accepts it; the plan is
serialized into the prompt for the existing generate→compile→retry loop, replacing
today's bare `userPrompt`. This separates "what are we building" from "write the
code" and gives the user a steering point.

Planning mode and screenshot feedback compose: a plan can reference the current
frame ("the glow is too green; make it red").

### 4. Iteration, history, and versioning

- **#82 (done):** chat history UI. — *shipped (in-memory).*
- **#83:** version rollback / branching. Persist generated versions so the user
  can jump back and branch. Needs a persistence decision per document type
  (bundles can store a `versions/` sidecar; flat `.metal` files have nowhere to
  stash history — pick a pragmatic default and document the limit). Must stay
  coherent with undo/redo (#76/#79): decide whether selecting an old version is
  an undoable text edit or a separate history mechanism.

### 5. Post-process / output quality (#91)

MetalFX spatial AI upscaling — orthogonal to generation, but part of the app's
overall "AI" story: render at a lower internal resolution and upscale. Listed
here for completeness; not part of the generation pipeline.

## Target end-state (narrative)

A user opens the Generate tab and describes an effect (or pastes a Shadertoy
shader). Optionally they enable "use current frame." The assistant first proposes
a **plan** it can read and tweak. On accept, the model generates the shader with
full context — the helper interface, the built-in textures, and (for vision
backends) the rendered frame — then compiles, self-corrects on errors, and shows
the result live. Each turn is a **versioned** entry in a persistent transcript;
the user can roll back to any version and branch. Follow-up prompts ("make it
pulse", "the red is too dark") refine the current version, with the live frame as
a visual reference.

## Non-goals

- Replacing the prompt with the image or the plan — both are *complements* to the
  user's stated intent.
- Backend-agnostic vision: only backends that support image input get the
  screenshot path; others gate it off.
- A general agentic loop that renders and re-prompts unattended (beyond #48's
  out-of-scope note). Keep the human in the loop.

## Open questions

- **Plan representation:** a `@Generable` `Plan` struct (structured, editable
  fields) vs. free-text the user edits. Structured is more steerable but more
  schema to maintain.
- **Version persistence (#83):** sidecar vs. embedded vs. in-memory, and how it
  reconciles with the undo stack.
- **Screenshot capture path (#48):** reuse the live `PhosphorView` render vs. a
  one-shot offscreen rasterize; PNG size/latency budget per turn.
- **Context budget:** the helper interface + built-in list + (eventually) a plan
  + an image is a lot of tokens. The on-device model can't take all of it; decide
  what each backend tier gets.
- **Multi-pass / feedback authoring:** planning mode implies pre-building
  ping-pong front-matter so the model only writes kernel logic. Does the schema
  need a richer "shape" hint than today's per-resource `pingPong` flag?
