# Shadertoy compatibility

Where Phosphor stands against Shadertoy's API surface, and what a port costs
today.

Audited August 2026, against PhosphorKit `main` and the lexical translator
added in #27. Each row was checked against the code, not against memory of
what Shadertoy does; the "how" column says where the support comes from.

Legend: ✅ works today · ⚠️ works with caveats · ❌ no equivalent yet.

## The short version

A single-pass Shadertoy shader that only uses `iTime`, `iResolution`,
`iMouse` and maths runs **unmodified**: paste it in and the translator
rewrites it. That is the large majority of Shadertoy by count.

What still costs manual work, roughly in order of how often you'll hit it:

1. Helper functions that read `iTime`/`iResolution` directly — Metal has no
   globals, so they need the value passed in as a parameter (#144).
2. GLSL idioms Metal's stricter type checker rejects (`1.0 / 2` and friends).
3. Wiring `iChannelN` to buffers on a multi-pass port — the structure translates, the routing can't (Shadertoy keeps it outside the source).
4. Non-image channel inputs: video, keyboard, cubemaps, 3D textures.

All of these fail loudly, as Metal compile errors. Nothing known renders
silently wrong.

## Uniforms and built-ins

| Shadertoy | Status | How |
|---|---|---|
| `iTime` | ✅ | `uniforms.time`; translator rewrites |
| `iTimeDelta` | ✅ | `uniforms.timeDelta` |
| `iFrame` | ✅ | `uniforms.frame` (a `float`, cast to `int` by the translator) |
| `iResolution` | ✅ | `float3(uniforms.resolution, 1)`. Shadertoy's `.z` is the pixel aspect ratio, effectively always 1 |
| `iFrameRate` | ⚠️ | Synthesised as `1 / timeDelta`. Shadertoy reports a smoothed rate; this is the instantaneous one |
| `iMouse` | ⚠️ | `float4(uniforms.mouse, uniforms.mouseClickOrigin)`. `xy` and the click origin match; Shadertoy's sign convention for "button currently down" on `zw` does not |
| `iDate` | ❌ | No wall-clock uniform. Cheap to add to `BuiltinUniforms` |
| `iSampleRate` | ❌ | No sound passes, so nothing to report |
| `iChannelTime[N]` | ❌ | Needs per-channel clocks, which only mean anything once video/audio channels exist (#118, #39) |
| `iChannelResolution[N]` | ❌ | The texture's size isn't surfaced to kernels. Add-able without much fuss |

Phosphor also has no Shadertoy equivalent for its own `uniforms.resized`
flag, user-declared uniforms (front-matter `[[uniforms]]`, with UI controls
and gesture bindings), or the waveform/spectrum audio buffers.

## Channel inputs

| Shadertoy | Status | How |
|---|---|---|
| Image textures | ✅ | `[[textures]]` with `init = { kind = "image", file = "…" }`, plus seven `builtin:` textures (mandrill, test card, four noise variants, blue noise) |
| Buffer A–D | ⚠️ | Translated. Mark the tabs with a comment (`// Buffer A`, `// Image`) since Shadertoy's tabs carry no in-source delimiter; each becomes a pass writing a `swap = "endOfFrame"` texture. Channel-to-buffer routing can't be recovered — Shadertoy stores it outside the source — so those bindings are wired by hand |
| Microphone | ✅ | `uniforms.waveform` (1024 time-domain samples) and `uniforms.spectrum` (512 FFT bins). Not a texture like Shadertoy's, so shaders index a buffer rather than sampling row 0/1 |
| Keyboard | ❌ | No key state anywhere in the runtime |
| Webcam | ❌ | #39 |
| Video | ❌ | #118 |
| Audio file | ❌ | Only live microphone input exists |
| Cubemaps | ❌ | Textures are `texture2d<float>` throughout |
| 3D / volume textures | ❌ | #92 |

## Pass types

| Shadertoy | Status | How |
|---|---|---|
| Image | ✅ | The normal case |
| Buffer A–D | ⚠️ | The runtime does multi-pass and ping-pong properly (`swap = "endOfFrame"` is exactly Shadertoy's semantics; `"immediate"` is an extra Phosphor offers). Porting is manual |
| Common | ✅ | Mark it `// Common` and it becomes top-level source, shared by every kernel — which is what Phosphor's single file gives for free |
| Cubemap | ❌ | Reported by the translator rather than mistranslated |
| Sound | ❌ | Ditto |

Phosphor adds one-shot passes (`once = true`, #104), which Shadertoy has no
equivalent for.

## Sampler behaviour

| Shadertoy | Status | How |
|---|---|---|
| Filter (linear/nearest) | ⚠️ | Not a channel property. Shaders declare their own `constexpr sampler`, so it's per-call rather than per-channel; the translator emits a linear/repeat sampler |
| Wrap (clamp/repeat) | ⚠️ | Same |
| VFlip | ⚠️ | There's a global `flipY` on the configuration, not a per-channel flag |
| sRGB | ❌ | Textures decode with `.SRGB: false`; no per-channel colour-space control |

## Output

| Shadertoy | Status | How |
|---|---|---|
| Single fullscreen image | ✅ | `output = "image"` |
| HDR / float buffers | ✅ | `rgba16Float` and `rgba32Float` texture formats |
| MRT | ✅ | Better than Shadertoy's: a pass can declare any number of `write` bindings |

## Language

| Shadertoy | Status | How |
|---|---|---|
| `mainImage(out vec4, in vec2)` | ✅ | Translator inlines the body into a generated kernel |
| `vec2`/`vec3`/`vec4`, `mat2`–`mat4`, `ivec`/`uvec`/`bvec` | ✅ | Renamed to MSL spellings |
| `texture()`, `texture2D()`, `textureLod()` | ✅ | Rewritten to `.sample(…)` |
| `texelFetch()` | ⚠️ | Rewritten to `.read(…)`; the lod argument is dropped, which is right for the non-mipmapped textures Phosphor allocates |
| `mix`, `smoothstep`, `fract`, `clamp`, … | ✅ | Same names and argument order in MSL |
| `#define` and the preprocessor | ✅ | Metal's preprocessor handles them |
| `gl_FragCoord` half-pixel offset | ✅ | The generated kernel uses `float2(gid) + 0.5` |
| Implicit int→float promotion | ❌ | `float x = 1;` and `vec2(1, 2.0)` compile on Shadertoy, not in Metal. Shows up as a compile error, so at least it's loud |
| `mod()` | ✅ | MSL has no `mod` at all; `Phosphor.h` supplies GLSL's (`x - y * floor(x / y)`), which differs from `fmod` for negative arguments |
| Built-ins inside helper functions | ❌ | Metal has no globals. The translator detects this and says so rather than emitting a confusing Metal error |
| Multiple GLSL versions | n/a | Shadertoy is effectively one dialect (GLSL ES 3.0-ish) |

## What would move the needle

Ordered by how much Shadertoy coverage each unlocks per unit of work.

1. **Built-ins in helper functions** (#144). The single biggest source of
   "it didn't compile" on otherwise-simple shaders. Needs either a real
   parse step to thread a uniforms parameter through, or a macro trick.
2. **`iChannelResolution`, `iDate`.** Small additions to `BuiltinUniforms`.
3. **Per-channel sampler state** (filter/wrap/sRGB/vflip). Currently
   shader-authored; making it a texture property matches Shadertoy and
   removes a class of subtle mismatches.
4. **Video and webcam channels** (#118, #39). Large — they need the first
   live-texture pathway — and they unlock a narrower slice than the above.

Note on failure modes: every known incompatibility on this page surfaces as
a Metal compile error rather than as wrong pixels. That's worth preserving.
It is why `mod()` is defined with GLSL's semantics rather than aliased to
`fmod()` — the alias would have compiled and then rendered incorrectly.

Keyboard, cubemap and sound passes are the long tail; each is a distinct
subsystem and none is on the critical path.
