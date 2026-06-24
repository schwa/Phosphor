# RFC-003: Conversational Generation via CollaborationKit

Status: Draft
Date: 2026-06-23
Related: RFC-002 (AI generation), ISSUES #82, #83, #93, #94
Depends on: [CollaborationKit](https://github.com/schwa/CollaborationKit)

## Summary

Phosphor's generation is **stateless turns plus breadcrumbs**: each request
spins up a fresh `LanguageModelSession`, and continuity across reopen is faked
by parsing `/* prompt: */` comments back out of the `.metal` file
(`PromptHistory`). That's the right shape for "one-shot generate / one-shot
modify" but the wrong shape for "keep talking to the model about this shader."

This RFC proposes a second, *conversational* generation mode backed by
[CollaborationKit](https://github.com/schwa/CollaborationKit): a persistent
`LLMSession` (an actor that owns the full message transcript) stored in the
document, driving a small set of shader-producing tools. It does **not** replace
the FoundationModels path — that stays for quick one-shot, on-device, and PCC
generation. It adds an agentic, "Claude Code for shaders" mode where the model
keeps real memory of what it tried.

## Motivation

### What we fake today

Two mechanisms stand in for memory:

- **`PromptHistory.extract`** reconstructs the conversation by scraping the
  leading `/* prompt: ... */` comments from the source and re-feeding them. The
  history lives in the *artifact*, not in a session. It captures only the
  user's prompts — never what the model said, planned, or tried.
- **`FoundationModelAdapter`** retains a `LanguageModelSession` *within one
  generation* (so the compile-retry turn has context), but that session is
  ephemeral. Close the document, reopen, hit Modify → brand-new session
  rehydrated from prompt comments.

So the model never sees its own prior reasoning, the compile errors it already
fixed, the resources it already chose, or the frames it already saw. Every
"modify" is effectively cold-start-with-notes. RFC-002's direction — plan,
multi-modal feedback, durable inspectable history (#82/#83/#93) — keeps running
into this: each feature has to re-derive context that a real session would
already hold.

### Why CollaborationKit fits

CollaborationKit's `LLMSession` is built around exactly the missing piece:

- It is an **actor that owns the conversation** — assistant text, tool calls,
  tool results, and cumulative token usage. Real, replayable memory.
- `LLMSession.messages` is exposed read-only; the package explicitly leaves
  persistence to the host ("serialize it yourself if you want to persist").
  That maps cleanly onto storing a transcript in a `.phosphor` bundle.
- The **agentic tool loop** is the Claude-Code shape: within one turn the model
  can call tools, read results, and correct itself — instead of Phosphor's
  host-driven "generate → compile → maybe one retry."
- It ships **provider abstraction** (Anthropic API key *or* Claude subscription
  via OAuth; OpenAI-compatible servers — LM Studio / Ollama / ds4) and per-turn
  token usage, none of which Phosphor has today.

The point is architectural, not incremental: CollaborationKit is a better
*substrate* for long-running memory than a session-per-generation that we
rehydrate from comments.

## The core mismatch (and how we resolve it)

Phosphor relies on FoundationModels' **guided generation**: `@Generable` +
`@Guide` constrain the decoder so the model is *forced* to emit JSON matching
`GeneratedShader` / `PlannedApproach`. CollaborationKit has no equivalent — it
returns text and runs a tool loop.

We recreate "structured output" as a **tool**:

- Register a CollaborationKit `Tool` whose `inputSchema` is the JSON Schema for
  `GeneratedShader`. The model produces a shader by *calling* `submitShader(...)`
  rather than by guided decode. Decode the tool's input into `GeneratedShader`,
  run it through the existing `toPhosphorConfiguration()` / compile path, and
  return the compile result *as the tool result* — so the model sees its own
  errors and can call the tool again. Same for `submitPlan` (#74).

Reliability note: with **Claude**, tool-use input is schema-validated
server-side and is very reliable. With **local OpenAI-compatible** models,
tool-calling quality varies (CollaborationKit's own README warns about this).
So this mode is strongest on Claude; local models are best-effort.

Cost note: the JSON Schema that `@Guide`/`@Generable` generate for free must be
hand-written for the tool (~6 types, ~25 fields). Tedious but mechanical, and a
candidate for later code-gen from the `@Generable` types.

## Design

### Two modes, one document

| | One-shot (today) | Conversational (new) |
|---|---|---|
| Backend | FoundationModels (`LanguageModelPort`) | CollaborationKit `LLMSession` |
| Backends available | on-device, PCC, Anthropic | Anthropic (key/OAuth), OpenAI-compatible |
| Memory | session-per-generation; `/* prompt: */` rehydrate | persistent transcript in document |
| Structured output | `@Generable` guided decode | `submitShader` / `submitPlan` tools |
| Loop | host-driven generate→compile→1 retry | agentic tool loop (model self-corrects) |
| Best for | quick, offline, private | iterative "talk to the shader" |

Both produce the same artifact: a `GeneratedShader` → `PhosphorConfiguration` →
`.metal` source via the existing adapter. The conversational mode reuses
`toPhosphorConfiguration()`, `FrontMatterFormatter`, the compile path, and the
undoable `TextMutator` write. No change to the runtime model.

### Tools we'd register

- **`submitShader`** — input schema = `GeneratedShader`. On call: decode →
  compile. Result returned to the model = compile success (with assembled
  source) or the Metal compiler errors. This subsumes RFC-002's compile-retry
  *and* malformed-retry (#94) into one loop: a decode failure or a compile
  failure is just a tool result the model reacts to, with no special host-side
  retry budget.
- **`submitPlan`** (optional, #74) — input schema = `PlannedApproach`. Lets the
  conversational mode do plan-then-generate in-session.
- **`readDocument`** — returns the current `.metal` source (the model can ask
  for context instead of us stuffing it into every prompt).
- *(Later)* **`renderFrame`** — returns a PNG of the current preview for vision
  backends (#48), as a tool the model can call on demand rather than a static
  attachment.

The system prompt reuses `GeneratorInstructions` plus the live
`PhosphorInterface.source` helper interface (#87/#88), unchanged.

### Persistence

Store the serialized `LLMSession.messages` transcript in the `.phosphor`
**bundle** (a `conversation.json` sidecar). This is the durable-history piece
RFC-002 #83 has been circling: the transcript *is* the history, and rolling back
becomes "truncate the transcript to message N and resume." Flat `.metal` files
have nowhere to stash a transcript — conversational mode is therefore a
**bundle-only** feature; flat files keep one-shot mode. This matches #83's
"pick a pragmatic default and document the limit."

### Inspectability (#93) comes for free

Unlike the Generable path (no raw token stream — RFC-002 explicitly notes this),
CollaborationKit emits a live `SessionEvent` stream (`textDelta`, `toolCall`,
`usage`, …) and retains full `messages`. A turn can be inspected as exactly what
was sent and received, including the model's prose between tool calls. The
"opaque turns" limitation in RFC-002 dissolves in this mode.

## Implementation sketch (phased)

1. **Vendor / depend on CollaborationKit** as an SPM dependency of
   `PhosphorSupport`. (It has no external deps beyond swift-argument-parser,
   which only the CLI target needs.)
2. **`GeneratedShader` JSON Schema** — author the `inputSchema` for the
   `submitShader` tool; round-trip-test it against the `@Generable` decode shape.
3. **`ShaderTools`** — `submitShader` (+ `submitPlan`, `readDocument`) over the
   existing compile/convert path. Tool result carries compile diagnostics.
4. **`ConversationalGenerator`** — owns an `LLMSession`, exposes a `send(prompt:)`
   that returns the produced `GeneratedShader` (decoded from the `submitShader`
   call) and streams `SessionEvent`s for the UI. Sibling to `ShaderGenerator`,
   not a `LanguageModelPort` conformer — the seam is different.
5. **Persistence** — serialize/restore `messages` in the bundle document.
6. **UI** — the Generate tab gains a mode toggle (or auto-selects conversational
   for bundles with a saved transcript). Stream tokens + tool calls into the
   existing transcript view; "roll back to here" truncates + resumes.
7. **Vision tool** (#48) and **plan tool** (#74) layer on without structural
   change.

Build and run unit tests after each phase (per AGENTS.md).

## Non-goals

- **Replacing FoundationModels.** One-shot / on-device / PCC stay. Many users
  want offline and private; the Apple path is the only one that delivers that.
- **Conversational mode for flat `.metal` files.** No place to persist a
  transcript; bundle-only.
- **Unattended agentic loops** (render-and-reprompt without a human). Same stance
  as RFC-002: keep the human in the loop.
- **Backend-uniform reliability.** Conversational structured output is reliable
  on Claude, best-effort on local models. We surface, not hide, that difference.

## Open questions

- **Schema maintenance.** Hand-written `submitShader` schema duplicates the
  `@Generable` shape. Acceptable now; worth a code-gen step later? Or is the
  duplication a smell that argues for a shared schema source feeding both paths?
- **Two seams or one.** Is `ConversationalGenerator` truly separate from
  `ShaderGenerator`, or can the compile-retry flow be expressed as a tool loop
  such that the FoundationModels path also funnels through tools? (Probably not
  worth forcing — Generable guided decode is genuinely better where it works.)
- **OAuth caveat.** CollaborationKit's subscription login uses the Claude Code
  OAuth client and is unofficial (may violate Anthropic's terms). Do we expose
  it in Phosphor at all, or restrict conversational mode to a billed API key?
- **Context budget.** A persistent transcript + helper interface + (later) frames
  grows unbounded. Need a trimming / summarization policy per backend tier — the
  same budget problem RFC-002 flags, now stateful.
- **Token-usage surfacing.** CollaborationKit reports per-turn usage; do we show
  a running cost in the conversational UI? (We have nothing comparable today.)
