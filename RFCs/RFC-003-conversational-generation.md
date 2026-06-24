# RFC-003: Conversational Generation via CollaborationKit

Status: Draft
Date: 2026-06-23
Updated: 2026-06-23 (concrete tool set; streaming-first UI; full conversation-model refactor)
Related: RFC-002 (AI generation), ISSUES #82, #83, #93, #94
Depends on: [CollaborationKit](https://github.com/schwa/CollaborationKit)

> **Direction note (2026-06-23):** this is now the *primary* generation model,
> not a bolt-on second mode. The existing stateless-turn + `PromptHistory`
> conversation model is to be **refactored away**, not preserved. Backwards
> compatibility with the current Generate-tab transcript is **not** a goal.

## Summary

Phosphor's generation is **stateless turns plus breadcrumbs**: each request
spins up a fresh `LanguageModelSession`, and continuity across reopen is faked
by parsing `/* prompt: */` comments back out of the `.metal` file
(`PromptHistory`). That's the right shape for "one-shot generate / one-shot
modify" but the wrong shape for "keep talking to the model about this shader."

This RFC proposes making *conversational* generation — backed by
[CollaborationKit](https://github.com/schwa/CollaborationKit) — the **primary**
generation model: a persistent `LLMSession` (an actor that owns the full message
transcript) stored in the document, driving a small set of shader-producing
tools, surfaced through a **streaming** chat UI. The current stateless-turn +
`PromptHistory` model is refactored away in favor of it. The FoundationModels
path stays available as a backend for quick one-shot, on-device, and PCC
generation, but the *conversation model* the app is built around becomes the
session-based, agentic, "Claude Code for shaders" one.

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

We recreate "structured output" as a **set of tools over the live document**.
Rather than one `submitShader` that emits a whole `GeneratedShader` per turn,
the conversational mode gives the model the same primitives a human editor has:
read/edit the Metal body, read/write the structured configuration, and compile
to check its work. The model converges by *editing and compiling*, not by
re-emitting the whole artifact.

Reliability note: with **Claude**, tool-use input is schema-validated
server-side and is very reliable. With **local OpenAI-compatible** models,
tool-calling quality varies (CollaborationKit's own README warns about this).
So this mode is strongest on Claude; local models are best-effort.

### The backing document

The single source of truth is the live `.metal` source in the editor — body
*and* front-matter together. We adapt Phosphor's editor buffer to
CollaborationKit's `TextDocument` protocol (`read() -> String` /
`write(String)`), routing `write` through the undoable `TextMutator` (#76) so
every model edit is a single undo step, exactly like a one-shot generation.
All four tools below operate on this one document; there is no separate copy
for the model to drift from.

### The four tools

| Tool | Mirrors | Operates on | Result to model |
|---|---|---|---|
| `editMetal` | CollaborationKit `EditTool` | Metal body | "Edit applied" / not-found / not-unique |
| `readConfiguration` | — | front-matter | structured config (TOML/JSON) |
| `writeConfiguration` | — | front-matter | re-emitted front-matter + diagnostics |
| `compileShader` | — | whole source | compile diagnostics / "compiles cleanly" |

**`editMetal`** — a near-verbatim port of CollaborationKit's `EditTool`: exact,
unique `oldText` → `newText` replacement, rejected if `oldText` is missing or
non-unique so the model adds context. Scoped to the Metal **body** (the source
with front-matter stripped, per `ParsedPhosphorSource.body`), so edits never
corrupt the structured block. This is the "edit the file like the sample file
tool" primitive — the model's main lever for iterating on kernel logic.

**`readConfiguration` / `writeConfiguration`** — the front-matter is
*structured*, not free text, so it gets typed tools instead of `editMetal`.
`readConfiguration` returns the parsed `PhosphorConfiguration`
(`PhosphorFrontMatter.parse(...).configuration`) serialized for the model.
`writeConfiguration` takes a structured configuration whose `inputSchema` is the
JSON Schema for `PhosphorConfiguration`, re-emits the front-matter block via
`FrontMatterFormatter`, splices it onto the current body, and writes back
through the document. The config typically changes little between turns (the
user's observation), so a coarse-grained read/write is the right grain — finer
than a whole-shader resubmit, structured enough to stay valid.

**`compileShader`** — the self-correction primitive. Parses the live source
(`ParsedPhosphorSource(source:)`), runs `ShaderCompiler.compile(parsed:device:)`
against the app's `MTLDevice`, and returns the result *as the tool result*:
`firstCompileError` plus front-matter/validation `diagnostics` on failure, or
"compiles cleanly" on success. Because this is a tool the model calls and reads,
RFC-002's host-driven "single compile retry" and the unbuilt malformed-retry
(#94) both collapse into the natural loop — the model edits, compiles, sees the
error, edits again, with no special host-side retry budget.

*(Later)* **`renderFrame`** — returns a PNG of the current preview for vision
backends (#48), as an on-demand tool rather than a static attachment.

Cost note: `writeConfiguration` needs a hand-written JSON Schema for
`PhosphorConfiguration` (the schema `@Guide`/`@Generable` generate for free on
the one-shot path). Smaller than the full `GeneratedShader` schema and a
candidate for later code-gen from the model types.

## Design

### Refactor, don't dual-path

The conversation model is **replaced**, not branched. We delete the
stateless-turn machinery whose only job was to fake memory — `PromptHistory`
(comment-scraping rehydration), the `/* prompt: */` breadcrumb writing, and the
host-driven single-retry flow in `ShaderGenerator` — and rebuild the Generate
tab around an `LLMSession`. Backwards compatibility with the current transcript
is explicitly not a goal (the transcript was in-memory and disposable anyway).

What survives is everything *below* the conversation seam: the runtime model,
`PhosphorConfiguration`, `FrontMatterFormatter`, `ShaderCompiler`, the helper
interface (#87/#88), and `TextMutator`. The model now reaches those through
tools instead of through a one-shot adapter.

The FoundationModels backends (on-device, PCC, Anthropic-via-Keychain) remain
selectable, but as *backends* under the session, not as a separate conversation
model. Where guided `@Generable` decode is wanted (e.g. on-device, which has no
reliable tool-calling), that backend can still be driven one-shot; but the app's
default, durable experience is the session.

| | Old (deleted) | New (primary) |
|---|---|---|
| Memory | session-per-generation; `/* prompt: */` rehydrate | persistent `LLMSession` transcript in document |
| Structured output | `@Generable` guided decode | tools over the live document |
| Loop | host-driven generate→compile→1 retry | agentic tool loop (model self-corrects) |
| UI | "title + elapsed" turn bubbles | streaming prose + inline tool calls |
| History | in-memory, lost on reopen | persisted transcript, rollback = truncate |

The artifact is unchanged: edits land in the live `.metal` source through the
undoable `TextMutator` path. No change to the runtime model.

### Tools we'd register

See "The four tools" above for the full set (`editMetal`, `readConfiguration`,
`writeConfiguration`, `compileShader`, and a later `renderFrame`). They share
one `TextDocument`-backed view of the live `.metal` source.

The system prompt reuses `GeneratorInstructions` plus the live
`PhosphorInterface.source` helper interface (#87/#88), unchanged, and tells the
model the loop: read the source, edit the body and/or configuration, then call
`compileShader` and fix any errors before finishing.

### Streaming UI

The Generate tab is rebuilt around the live event stream, not around discrete
"turn" records. `LLMSession.events` yields `SessionEvent`s — `textDelta`,
`toolCall`, tool results, `usage` — which the UI consumes as they arrive:

- **Assistant prose streams in token-by-token** (`textDelta`) into the
  transcript, the way a chat client renders a live reply.
- **Tool calls render inline** as they happen: "editing body…", "compiling…",
  with the result (applied / compile error) filling in when the tool returns.
  The user watches the model edit-and-compile in real time.
- **Live document updates**: because the tools write through the shared
  `TextDocument`, the editor and preview update *during* the turn — the shader
  recompiles and re-renders as the model edits, not only at the end.
- **Token usage** ticks up live from `usage` events.

This replaces the current "title + elapsed time" turn bubble (RFC-002's "opaque
turns" limitation, #93) with a transparent, streaming view of exactly what the
model is doing.

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

1. **Depend on CollaborationKit** — add it as an SPM dependency of
   `PhosphorGeneration`. (No external deps beyond swift-argument-parser, used
   only by its CLI target.)
2. **`MetalSourceDocument`** — a `TextDocument` adapter over the editor buffer,
   writing through `TextMutator` for undoable, single-step edits.
3. **`compileShader` tool** first — pure (`ParsedPhosphorSource` +
   `ShaderCompiler.compile`), no schema, independently testable with a fake
   device. Validates the tool-result-as-feedback loop in isolation.
4. **`editMetal` tool** — port CollaborationKit's `EditTool`, scoped to the
   body. Unit-test not-found / not-unique / applied.
5. **`PhosphorConfiguration` JSON Schema** + **`readConfiguration` /
   `writeConfiguration`** — author and round-trip-test the schema against
   `FrontMatterFormatter` encode/decode.
6. **`ConversationalGenerator`** — owns an `LLMSession` wired with the four
   tools, exposes `send(prompt:)`, and re-exposes the `SessionEvent` stream for
   the UI. Replaces `ShaderGenerator` as the app's generation entry point.
7. **Delete the old conversation model** — remove `PromptHistory`, the
   `/* prompt: */` breadcrumb writing, and `ShaderGenerator`'s host-driven
   retry flow once the session path is wired.
8. **Streaming UI** — rebuild the Generate tab around `LLMSession.events`:
   token-streamed prose, inline tool-call rows, live editor/preview updates.
9. **Persistence** — serialize/restore `LLMSession.messages` in the bundle
   document; "roll back to here" truncates + resumes.
10. **Vision tool** (#48) and **plan tool** (#74) layer on without structural
    change.

Build and run unit tests after each phase (per AGENTS.md).

## Non-goals

- **Preserving the old conversation model.** `PromptHistory`, the
  `/* prompt: */` breadcrumbs, and the host-driven retry flow are removed.
  Backwards compatibility with the current Generate-tab transcript is not a
  goal.
- **Dropping FoundationModels entirely.** The Apple backends (on-device, PCC,
  Anthropic-via-Keychain) stay available as *backends* — important for offline
  and private use — but no longer define the conversation model.
- **Conversational persistence for flat `.metal` files.** No place to stash a
  transcript; persistent sessions are bundle-only. A flat file gets an
  in-memory session that's discarded on close.
- **Unattended agentic loops** (render-and-reprompt without a human). Same stance
  as RFC-002: keep the human in the loop.
- **Backend-uniform reliability.** Tool-driven structured output is reliable on
  Claude, best-effort on local models. We surface, not hide, that difference.

## Open questions

- **Schema maintenance.** The hand-written `writeConfiguration` schema
  duplicates `PhosphorConfiguration`'s Codable shape. Acceptable now; worth a
  code-gen step later?
- **FoundationModels under the session.** Can the Apple backends be driven
  through the same tool loop, or do they stay a separate one-shot path for
  on-device (where tool-calling is unreliable)? Likely the latter, selected by
  backend capability.
- **OAuth caveat.** CollaborationKit's subscription login uses the Claude Code
  OAuth client and is unofficial (may violate Anthropic's terms). Do we expose
  it in Phosphor at all, or restrict conversational mode to a billed API key?
- **Context budget.** A persistent transcript + helper interface + (later) frames
  grows unbounded. Need a trimming / summarization policy per backend tier — the
  same budget problem RFC-002 flags, now stateful.
- **Token-usage surfacing.** CollaborationKit reports per-turn usage; do we show
  a running cost in the conversational UI? (We have nothing comparable today.)
