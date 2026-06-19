# RFC-001: Texture Model Redesign

Status: Draft
Tracking issue: [#50](../ISSUES.md)
Date: 2026-06-19

## Summary

Replace the current three-headed texture model (split between `Resource.texture2D` / `Resource.image`, `TextureInit` fields, `pingPong` + `flipTiming` flags) and the Shadertoy-style `iChannelN` binding system with a single coherent design:

1. Textures are declared at the env level and have *actions* attached (`init`, `swap`). No more two-shape `Resource` enum.
2. Per-pass texture bindings are **named by the texture's id**, with a per-binding `access` mode (`read` / `sample` / `write` / `read_write`).
3. The kernel sees one nested `Textures` struct inside `Uniforms&`. No more `ChannelBindings&`, no more special `outTexture [[texture(0)]]` parameter.
4. `gid` is declared at file scope via `[[thread_position_in_grid]]`. Kernel signatures drop it as a parameter.

The canonical example is `Examples/HelloWorld.metal` (already in the new shape, but the runtime can't render it yet).

## Motivation

See [#50](../ISSUES.md). Short version: the current model has three orthogonal concerns (resource kind, init contents, swap behavior) encoded as overlapping fields on overlapping enums. It also distinguishes "outputs" and "inputs" inside the kernel even though both are just textures with different access modes. The redesign collapses all of this onto one consistent shape that's easier to learn, easier to document, and easier to extend.

## Non-goals

- Backwards compatibility with the existing TOML front-matter shape. Hard cut.
- Sampler objects as first-class bindings.
- Buffer resources alongside textures.
- True simultaneous `access::read_write` on compute outputs (Metal still doesn't make that ergonomic).
- Porting the 35 archived shaders in `Old Examples/` as part of this RFC. Those get ported one at a time afterward.

## Target shape (TOML)

```toml
/* phosphor:environment
output = "output"

[[textures]]
id = "output"
size = "drawable"
format = "rgba32Float"
init = { kind = "fill", color = [0.0, 0.0, 0.0, 1.0] }
swap = "none"

[[passes]]
id = "helloWorld"
textures = [
    { id = "output", access = "write" },
]
*/
```

## Target shape (kernel)

```metal
uint2 gid [[thread_position_in_grid]];

kernel void helloWorld(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    float pulse = 0.5 + 0.5 * sin(uniforms.time);
    uniforms.textures.output.write(float4(uv.x, uv.y, pulse, 1.0), gid);
}
```

## Detailed design

### Swift model

- **`Resource` enum goes away.** Replaced by a flat `Texture` value type:
  ```swift
  public struct Texture: Hashable, Sendable, Codable {
      public var id: ResourceID
      public var size: TextureSize          // .drawable | .fixed(w, h) | .scaledDrawable(s)
      public var format: PhosphorPixelFormat
      public var init: TextureInit          // .zero | .fill(SIMD4<Float>) | .image(file:) | .noise(seed:)
      public var swap: SwapTiming           // .none | .endOfFrame | .immediate
  }
  ```
- **`TextureInit`** keeps the existing cases but renames `.color(_)` → `.fill(_)` to match the TOML kind. `.image(name:)` becomes `.image(file: String)` to make it explicit that the value is a filename inside `assets/`.
- **`SwapTiming`** replaces `pingPong: Bool` + `flipTiming`. Cases: `.none`, `.endOfFrame`, `.immediate`. (`.immediate` stays unimplemented per existing #4 — but the model carries it.)
- **`Pass.inputs: [Pass.Input]`** is renamed `Pass.textures: [Pass.TextureBinding]`:
  ```swift
  public struct TextureBinding: Hashable, Sendable, Codable {
      public var id: ResourceID
      public var access: TextureAccess      // .read | .sample | .write | .readWrite
  }
  ```
  The binding's name in the kernel IS the texture's id. No separate `name` field.
- **`TextureAccess`** gains a `.write` and `.readWrite` case alongside the existing `.read` and `.sample`.
- **`PhosphorEnvironment.resources`** is renamed `textures` and becomes `[Texture]`.
- **`PhosphorEnvironment.output`** stays — it's the env-level "which texture do we blit to the drawable." Distinct from per-pass outputs.

### Codable / TOML

- All field names match the table above. Sensible defaults: omitted `size` → `"drawable"`, omitted `format` → `"rgba32Float"`, omitted `init` → `{ kind = "zero" }`, omitted `swap` → `"none"`.
- The `init` table uses the `kind = "..."` discriminator: `"zero"`, `"fill"`, `"image"`, `"noise"`. Other fields depend on kind.
- `FrontMatterFormatter` re-encodes the new shape with the same inline-leaf-table style.

### Kernel codegen (PhosphorHeader)

- Emit `Textures` struct inside `Uniforms`, populated from the *binding list* of the pass currently being compiled. The struct's fields use the binding `id` as the field name; the MSL access qualifier matches the binding `access`:
  ```metal
  struct Textures {
      texture2d<float, access::write>  output;
      texture2d<float, access::sample> photo;
  };
  ```
- The `Uniforms` struct gains a `Textures textures;` field at the end (after `waveform` / `spectrum`).
- Drop `ChannelBindings` entirely. Drop `iChannelN` slot inference. Drop the `channelCount` field on `Uniforms`.
- The `Phosphor.h` doc-comment header for each pass mentions which textures are in scope.
- Per-pass codegen: each pass gets its own `Textures` struct definition because access modes per binding can differ between passes. (Today the `ChannelBindings` struct is env-wide; we're trading that for per-pass.)

### Runtime

- `PhosphorRuntime.textures` continues to key by `ResourceID`. Allocation honors the new `Texture` shape; init kind drives initial-contents behavior.
- `writeChannelBuffers(parity:)` becomes `writeTextureBuffers(parity:)`. Per pass, fill an argument buffer with `MTLResourceID` handles, one per binding. The buffer is mapped at the offset Metal expects for the nested `textures` field inside `Uniforms`. (Open question — see below.)
- `PhosphorPipeline` stops binding `[[texture(0)]]` for the output. Stops binding `[[buffer(1)]]` to a channel argbuffer. Binds the new combined uniforms argbuffer at `[[buffer(0)]]` and the user uniforms argbuffer at `[[buffer(1)]]`.
- Removal of the special output texture means the runtime determines the *primary write target* of a pass by walking its bindings for `access == .write` or `.readWrite`. Validation requires at least one such binding.

### Validation

- A pass with no `access = "write" | "read_write"` binding fails validation.
- A binding referencing an undeclared texture id fails validation (unchanged from today).
- A pass that writes to a texture whose `swap = "none"` AND also reads it via another binding in the same pass is still a hazard (today's `readWriteHazard` rule, restated).
- The env's `output` must point at a declared texture.

### Generator

- `GeneratedShader` (the `@Generable` Foundation Models schema) updates to mirror the new shape: `GeneratedTexture` with `id` / `size` / `format` / `init` / `swap`; `GeneratedPassBinding` with `id` / `access`. No more `GeneratedBinding` with `iChannelN` slot names.
- Instructions string in `ShaderGenerator` rewrites to teach the new shape, including the `Textures` nesting inside `Uniforms` and the file-scope `gid` declaration.

### Document templates

- `PhosphorMetalDocument.template` and `PhosphorBundleDocument.template` get rewritten to match `HelloWorld.metal`.

### Open questions

1. **Nested argbuffer encoding.** MSL accepts `Textures` nested inside `Uniforms&` (verified by probe). But on the host side we need to write `MTLResourceID` handles into the right offset within the uniforms buffer. Metal's `MTLArgumentEncoder` can encode nested structs, but the simpler path is to lay out the offsets by hand. Likely a hand-rolled offset computation. Needs prototyping during step 2 of the execution plan.
2. **Init kind names.** `"fill"` is new; matches the example. `"image"` stays. Do we want `"zero"` as a shortcut for `fill { color = [0, 0, 0, 0] }`, or drop it for one canonical kind? Defer to a follow-up; ship `"zero"` and `"fill"` both for now.
3. **Per-pass `Textures` vs env-wide.** Per-pass means each pass's kernel sees only the bindings it declared, with the access qualifiers it specified. Cleaner ergonomically; slightly more codegen. Going per-pass.
4. **Sensible defaults for missing top-level fields.** Out of scope here; tracked separately on #51. After this RFC lands, single-pass shaders with default everything should be near-empty front-matter (one `[[textures]]`, one `[[passes]]`).
5. **`gid`-as-global** (#28). The example already uses it. Plumb through the codegen so the generator instructions show this style and the kernel signature drops `uint2 gid [[thread_position_in_grid]]` as a parameter.

## Execution plan

Each step ends with a passing build + the smoke test running `HelloWorld.metal` successfully (or, in the early steps, with the test temporarily disabled until the runtime catches up).

1. **Model layer.** Replace `Resource` with `Texture`. Rewrite `TextureInit` cases. Add `SwapTiming` enum. Update Codable + Validation. Update tests (delete or rewrite the old `ValidationTests` cases). Smoke test stays disabled.
2. **Header generator.** Rewrite `PhosphorHeader` to emit the new `Uniforms` shape with nested `Textures`. Drop `ChannelBindings`. Drop `channelCount`. Update `BuiltinUniforms` Swift struct to match the new layout. Validate by hand against the prototype.
3. **Runtime.** Rewrite `PhosphorRuntime.ensureTextures` for the new `Texture` shape. Rewrite the argbuffer encode path (texture handles inside the uniforms arg buffer). Rewrite `PhosphorPipeline` to drop the `outTexture` parameter and bind only the two uniforms buffers. Get the smoke test green again on `HelloWorld.metal`.
4. **Generator + templates.** Update `GeneratedShader` schema. Rewrite `ShaderGenerator.instructions`. Update both document templates.
5. **Audit + cleanup.** Delete dead code. Verify swiftlint passes. Verify all tests pass.

Steps 1–3 are the bulk of the work and should land together — the codebase doesn't compile usefully in between. Step 4 + 5 are independent and can land separately.

## Risks

- **The argbuffer offset hand-rolling is the most likely place for runtime corruption.** If `Textures.foo` ends up at the wrong byte offset relative to the rest of `Uniforms`, the kernel will read garbage handles. Mitigation: write a unit test that dumps the encoded buffer's layout and compares it to MSL's expectations via a known-good `MTLArgumentEncoder` run.
- **All 35 archived shaders need porting eventually.** That's not part of this RFC, but it's the realised cost of the hard-cut decision.
- **Generator quality regressions.** The model needs to learn the new shape from the instructions string alone. Likely needs several retry-test cycles to get the prompt right.

## Alternatives considered

- **Soft migration.** Accept old front-matter AND new for one release. Rejected: doubles surface area, doubles tests, the generator has to know both shapes.
- **Keep `ChannelBindings` separate from `Uniforms`.** Rejected because the user explicitly wants textures nested into Uniforms (option A from the design dialog).
- **Keep `iChannelN` numeric slots but allow per-slot access.** Rejected; doesn't solve the naming-inconsistency problem.
- **Per-binding `init` and `swap` overrides.** Rejected for v1 — texture-level is the right place; if a pass wants different per-frame behavior, it should declare a different texture.
