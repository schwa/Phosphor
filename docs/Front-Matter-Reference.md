# Front-matter reference

Every Phosphor shader carries a configuration: which textures exist, which
passes run, what the user can tweak. In a `.metal` document it lives in a
TOML comment at the top of the file:

```metal
/* phosphor:environment
output = "image"

[[textures]]
id = "image"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
]
*/

uint2 gid [[thread_position_in_grid]];

kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    float2 uv = float2(gid) / uniforms.resolution;
    uniforms.textures.image.write(float4(uv, 0.0, 1.0), gid);
}
```

`.phosphor` documents hold the same configuration as JSON alongside the
source, and `.phosphord` bundles hold one per shader. The keys are identical
in all three; only the encoding differs.

The block must be the first thing in the file apart from whitespace, line
comments and other block comments — so a generated shader can carry a
`/* prompt: … */` header above it.

## Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `output` | string | *required* | Id of the texture blitted to the screen. Almost always `"image"`. |
| `textures` | array of table | `[]` | Texture resources. See below. |
| `passes` | array of table | `[]` | Compute passes, run in declaration order. |
| `uniforms` | array of table | `[]` | User-facing controls. |
| `flipY` | bool | `false` | Flip the final blit vertically. For GLSL-convention shaders that put Y=0 at the bottom; Phosphor puts `gid.y = 0` at the top. |

## `[[textures]]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | *required* | Name, referenced by passes and by `output`. |
| `size` | see below | `"drawable"` | Pixel dimensions. |
| `format` | string | `"rgba32Float"` | One of `rgba8Unorm`, `bgra8Unorm`, `rgba16Float`, `rgba32Float`. |
| `swap` | string | `"none"` | Ping-pong behaviour: `none`, `endOfFrame`, `immediate`. |
| `init` | see below | `{ kind = "zero" }` | Contents at materialisation. |

### `size`

```toml
size = "drawable"                            # matches the view, resizes with it
size = { fixed = { width = 512, height = 512 } }
size = { scaledDrawable = 0.5 }              # half the view, and stays half
```

A texture whose size depends on the drawable is reallocated (and zeroed) when
the window resizes. `uniforms.resized` is `1` on the frame after that happens,
which is how feedback shaders know to re-seed.

### `swap`

`none` gives one texture: reads and writes hit the same memory.

`endOfFrame` gives two and flips between them at the end of each frame, so a
pass reading the texture sees *last* frame's contents. This is Shadertoy's
buffer behaviour and what you want for feedback:

```toml
[[textures]]
id = "image"
swap = "endOfFrame"

[[passes]]
id = "image"
textures = [
    { id = "image", access = "write" },
    { id = "image", access = "read", name = "imagePrev" },
]
```

The two bindings need distinct `name`s because they become distinct fields on
the kernel's `textures` struct — write through `uniforms.textures.image`, read
through `uniforms.textures.imagePrev`.

`immediate` flips right after the writing pass instead, so a later pass in the
*same* frame sees the just-written data. Phosphor-specific; Shadertoy has no
equivalent.

### `init`

```toml
init = { kind = "zero" }                                  # the default
init = { kind = "fill", color = [1.0, 0.0, 0.0, 1.0] }
init = { kind = "image", file = "mandrill" }              # an asset, or a builtin
init = { kind = "noise", seed = 42 }
```

Write float components with a decimal point. TOML distinguishes integers from
floats and the decoder doesn't coerce, so `color = [1, 0, 0, 1]` fails with
`Cannot decode "Float" from 1`. Same for a `float` uniform's `default`.

Image lookups try the literal name, then the name without its extension, then
the built-in registry — so `file = "mandrill"` finds `mandrill.png` in a
bundle, or falls back to `builtin:mandrill`. The built-ins are `mandrill`,
`testcard`, `noise-white`, `noise-white-rgb`, `noise-value`, `noise-fbm` and
`noise-blue`, all reachable with or without the `builtin:` prefix.

Image-initialised textures take the decoded image's size, ignoring `size`, and
can't be ping-pong.

## `[[passes]]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | *required* | Also the kernel function name: `kernel void <id>(...)`. |
| `textures` | array of table | `[]` | Bindings. Each needs at least one write. |
| `enabled` | bool | `true` | Skip the pass without deleting it. |
| `once` | bool | `false` | Run at init instead of every frame. |

A `once` pass runs on the first frame after its state is invalidated —
reload, reset, or a texture reallocation — and is skipped otherwise. Use it to
precompute something a per-frame pass reads. Don't use it to seed a ping-pong
texture: a single run only fills the half matching that frame's parity.

### Bindings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | *required* | Which texture. |
| `access` | string | `"read"` | `read`, `sample`, `write`, or `readWrite`. |
| `name` | string | the id | Field name in the kernel's `textures` struct. |

Every pass must declare at least one `write` or `readWrite` binding. Reading
and writing the same texture in one pass is a hazard unless it's ping-pong,
and is reported as one.

## `[[uniforms]]`

Declared uniforms appear in the Uniforms panel and arrive in the kernel as
`userUniforms.<name>`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | *required* | Field name in `UserUniforms`. |
| `kind` | string | *required* | `float`, `float2`, `float3`, `float4`, `int`, `bool`, `color`. |
| `default` | value | *required* | Initial value; a number, bool, or array. |
| `ui` | see below | derived | Control to show. |
| `gesture` | string | none | Bind to a preview gesture. `float` only. |

```toml
[[uniforms]]
name = "frequency"
kind = "float"
default = 6.0
ui = { slider = { min = 0.5, max = 24.0 } }

[[uniforms]]
name = "tint"
kind = "color"
default = [0.6, 0.8, 1.0, 1.0]
ui = "color"
```

As with `fill` above, float defaults need a decimal point: `default = 6` is a
TOML integer and won't decode as a `float` uniform.

`ui` is one of `{ slider = { min, max } }`, `"color"`, `"toggle"`, or
`"vector"`.

`gesture` is `x`, `y`, `zoom` or `rotate`. A drag, pinch or rotation on the
preview then drives the uniform, mapped into its slider range. Each gesture
can be claimed by at most one uniform.

## What the kernel sees

`uniforms` is the per-pass argument buffer:

| Field | Type | Meaning |
|---|---|---|
| `time` | float | Seconds since the document opened. |
| `timeDelta` | float | Seconds since the previous frame. |
| `frame` | float | Frame counter, from 0. |
| `resolution` | float2 | Drawable size in pixels. |
| `mouse` | float2 | Cursor position in pixels. |
| `mouseButtons` | uint | Bitmask of held buttons; bit 0 is the left. |
| `mouseClickOrigin` | float2 | Cursor position when the current press started. |
| `resized` | uint | `1` on the frame after a resize, else `0`. |
| `waveform` | `device const float*` | 1024 microphone samples in −1…1. |
| `spectrum` | `device const float*` | 512 FFT magnitudes in 0…1. |
| `textures` | struct | One field per binding this pass declares. |

The audio buffers are always bound; they're zero-filled when the microphone is
off, so a shader can read them unconditionally.

`gid` is declared once at file scope, not per kernel:

```metal
uint2 gid [[thread_position_in_grid]];
```

Re-declaring it inside a kernel is a redefinition error.

## Validation

Structural problems are reported in the diagnostics banner rather than
throwing: a pass with no write binding, a binding naming a texture that
doesn't exist, duplicate ids, `output` naming nothing, a read/write hazard, an
image texture asking for ping-pong, a `gesture` on a non-float, or two
uniforms claiming the same gesture.

## See also

- [Shadertoy compatibility](Shadertoy-Compatibility.md) — what a Shadertoy
  port costs, and what the translator rewrites for you.
- [`Examples/README.md`](../Examples/README.md) — a tour of the shipped
  shaders, tagged by which feature each one demonstrates.
