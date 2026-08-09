# Examples

`Examples.phosphord` is the bundle Phosphor offers from the splash screen
("Examples…"). It expands into a writable `.phosphord` you can edit freely —
the copy in this repo is the pristine one.

Each shader is a single `kernel void image(...)` unless the table says
otherwise. Tags mark which Phosphor feature a shader is worth reading for:

| Tag | Meaning |
|---|---|
| **feedback** | Ping-pong texture (`swap`), reads its own previous frame |
| **multipass** | More than one `[[passes]]` entry |
| **uniforms** | Declares `[[uniforms]]`, so it has live controls in the Uniforms panel |
| **audio** | Reads `uniforms.waveform` / `uniforms.spectrum` (needs the microphone enabled) |
| **mouse** | Responds to `uniforms.mouse` |
| **texture** | Samples an image asset |

## Start here

| Shader | Tags | Description |
|---|---|---|
| SolidColor | | Dim grey everywhere. The smoke test for the render path — the smallest thing that can work. |
| HelloWorld | | Pulsing UV gradient. One pass, one texture, no uniforms: the minimal *interesting* shader. |
| Plasma | uniforms | Classic procedural plasma from a sum of sine waves, with live controls. |
| Checkerboard | mouse | Animated scrolling checkerboard with colour tinting. |
| TextureDemo | texture | Samples the bundled `mandrill.png` and writes it out. The image-asset reference. |

## Feedback and simulation

These read their own previous frame, so they're the ones to read when writing
anything stateful.

| Shader | Tags | Description |
|---|---|---|
| GameOfLife | feedback | Conway's Game of Life, one generation per frame. |
| Lifeish | feedback | Life variant with decaying colour trails; hue tracked separately so trails fade to true black. |
| Mold | feedback, mouse | Gray-Scott reaction-diffusion producing a creeping fungal mould. |
| Fluids | feedback, mouse | Semi-Lagrangian fluid: velocity and dye advection with mouse injection and dissipation. |
| Lightning | feedback | Decaying feedback pass building forked lightning. |
| Bloom | feedback, multipass, uniforms | The multi-pass reference: `bufA` draws a moving dot with a decaying trail, then `image` box-blurs it to screen. |

## Raymarching and 3D

| Shader | Tags | Description |
|---|---|---|
| SDF | uniforms | Sphere/cube smooth union with Blinn-Phong shading and a controllable camera distance. |
| RaymarchingSphere | mouse | Straightforward sphere raymarch. Phosphor 1 port. |
| Great Pyramid SDF | | Square-based pyramid on desert sand, with warm lighting. |
| Planter | | Procedural terracotta plant pot with soil, soft shadows and ambient occlusion. |
| Clouds | uniforms | Single-pass volumetric cloud raymarcher. |
| Voxels | uniforms | Procedural voxel terrain traversed with DDA. |
| Terrain | uniforms | Value-noise terrain. |
| TerrainRiver | mouse | Terrain with a river running through it. Phosphor 1 port. |
| HSVRaymarch | mouse | Raymarched scene shaded through HSV colour space. Phosphor 1 port. |
| Mouse Cube | mouse | Wireframe cube rotated by the cursor. |
| IQBricks | uniforms | Brick-cylinder raymarcher, after Inigo Quilez. Educational use only. |

## Audio reactive

Enable the microphone in the toolbar first, or these render flat.

| Shader | Tags | Description |
|---|---|---|
| AudioProbe | feedback, uniforms, audio | Draws the live waveform with adjustable gain and fading trails. The audio reference. |
| AudioSmileyFace | audio | A smiley face whose mouth opens with the input level. |

## Mouse

| Shader | Tags | Description |
|---|---|---|
| MouseProbe | mouse | HAL 9000's eye tracking the cursor, with animated pod-bay doors. |

## Procedural scenes and effects

| Shader | Tags | Description |
|---|---|---|
| 2001 | uniforms | The *2001* stargate slit-scan corridor, as two mirrored halves. |
| Sunspots | uniforms | Glowing sun disc with a roiling granulated surface and sunspots. |
| Fire | mouse | Rising procedural flame. Phosphor 1 port. |
| Fireworks | | Animated firework bursts with particle trails and gravity. |
| Confetti | | Falling confetti in assorted colours, sizes and rotations. |
| Underwater Caustics | | Procedural caustics; stateless and single-pass. |
| Orange | uniforms | Orange-peel bump field built from summed value noise. |
| Noise | | Hash-based salt-and-pepper noise, animated per frame. |
| NoiseFlow | mouse | Flowing noise field. Phosphor 1 port. |
| VoronoiCells | mouse | Animated Voronoi cells. Phosphor 1 port. |
| IterativeTrig | mouse | Iterated trigonometric warping. Phosphor 1 port. |
| PlasmaClassic | mouse | The older plasma formulation. Phosphor 1 port. |
| FractalPlant | mouse | Fractal plant / L-system-ish growth. Phosphor 1 port. |
| Cityscape | mouse | Procedural city skyline. Phosphor 1 port. |
| Heart | mouse | Beating heart. Phosphor 1 port. |
| HelloTriangle | mouse | A triangle, the traditional way. Phosphor 1 port. |

## Pixel art and figurative

| Shader | Tags | Description |
|---|---|---|
| Pacman | | Pac-Man chomping his way across a black maze. |
| SuperMario | uniforms | Super Mario-inspired pixel-art blocks. |
| Pelican | uniforms | A pelican drawn from signed distance functions. |

## A note on the Phosphor 1 ports

Shaders tagged "Phosphor 1 port" keep their original `mainImage(...)`
function and wrap it in a thin `kernel void image(...)` that forwards the
uniforms. They work, but they aren't the idiomatic way to write a Phosphor 2
shader — read `HelloWorld` or `Bloom` for that.
