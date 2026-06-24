# AGENTS.md — Phosphor

A Shadertoy-like playground for Metal compute shaders, with AI-assisted shader
generation. Built on MetalSprockets.

## Sibling project: PhosphorKit is PART of this project

`~/Projects/Current/PhosphorKit` is a **separate git repo** but is considered
**part of the Phosphor project**. Treat changes there as in-scope when working
on Phosphor.

- **PhosphorKit is the single source of truth for parse / compile / render.**
  It vends the `PhosphorModel`, `PhosphorCompile`, and `PhosphorRuntime`
  libraries. These targets used to live in `Packages/PhosphorSupport` and were
  ported out; do **not** re-add them to PhosphorSupport.
- The Phosphor app links `PhosphorModel` / `PhosphorCompile` / `PhosphorRuntime`
  directly from PhosphorKit via a GitHub package reference in the Xcode project
  (`https://github.com/schwa/PhosphorKit`, branch `main`).
- `Packages/PhosphorSupport` now only contains `PhosphorGeneration` (the AI
  shader-generation layer). It depends on PhosphorKit's `PhosphorModel` and
  `PhosphorCompile` products via the same GitHub package
  (`https://github.com/schwa/PhosphorKit`, branch `main`).

The local checkout at `~/Projects/Current/PhosphorKit` is still the working
copy for editing PhosphorKit; push changes there and the app/PhosphorSupport
pick them up from `main`.

When you change parse/compile/render code, edit it in **PhosphorKit**, not in
PhosphorSupport.

## Where things live

- `Phosphor/` — the macOS app (SwiftUI views, document model, generation UI glue).
- `Packages/PhosphorSupport/Sources/PhosphorGeneration` — AI generation only.
- `~/Projects/Current/PhosphorKit/Sources/`
  - `PhosphorModel` — core data model (+ BuiltinTextures, StarterTemplate.metal).
  - `PhosphorCompile` — tree-sitter parsing, source assembly, Metal compile (owns Phosphor.h).
  - `PhosphorRuntime` — MetalSprockets render pipeline + audio capture.

## Building

- App: `xcb build --target Phosphor` from the Phosphor project root.
- PhosphorKit: `swift build` / `xcb test` from `~/Projects/Current/PhosphorKit`.
- PhosphorSupport: `swift build` from `Packages/PhosphorSupport`.
- If `xcb` shows stale targets after editing a `Package.swift`, run `xcb flush`.

## Known pre-existing issues

- `PhosphorRuntimeTests` "Voxels" example fails (broken example shader,
  `missingOutput(image)`) — predates the PhosphorKit port.
