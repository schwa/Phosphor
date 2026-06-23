/* prompt: game of life */
/* prompt: now with a slightly different rule set */
/* prompt: more colors */
/* prompt: use rainbow colors */
/* prompt: the colours are still blue/yellow */
/* prompt: use a black backgound */
/* prompt: background is not black */

/* phosphor:environment
output = "image"
uniforms = []

[[passes]]
enabled = true
id = "image"
textures = [ { access = "write", id = "image" }, { access = "read", id = "image", name = "imagePrev" } ]

[[textures]]
format = "rgba32Float"
id = "image"
init = { kind = "zero" }
size = "drawable"
swap = "endOfFrame"
*/

uint2 gid [[thread_position_in_grid]];

/// Simple hash for random seeding.
static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

/// Convert an HSV color to RGB. Used for hue-based cell coloring.
static float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

/// HighLife (B36/S23): a Game-of-Life variant where a dead cell is also
/// born with exactly 6 live neighbours. The authoritative alive/dead state
/// is stored separately in the alpha channel, while a rainbow hue + fading
/// trail is packed into RGB for display. Dead cells with no trail are
/// rendered as pure black. Hue is tracked separately so the trail value
/// can decay all the way to 0 (true black) regardless of the cell's hue.
/// Reads previous state from imagePrev, writes next state to image.
kernel void image(
    device const Uniforms&     uniforms     [[buffer(0)]],
    device const UserUniforms& userUniforms [[buffer(1)]])
{
    int2 res = int2(uniforms.resolution);
    if (gid.x >= uint(res.x) || gid.y >= uint(res.y)) return;

    const int cell = 4;
    int2 coord = int2(gid);
    int2 cellCoord = coord / cell;
    int2 grid = res / cell;

    // Seed frame: randomize.
    if (uniforms.frame < 1.0 || uniforms.resized != 0u) {
        float r = hash(float2(cellCoord));
        float alive = r > 0.7 ? 1.0 : 0.0;
        float hue = fract(float(cellCoord.x + cellCoord.y) * 0.01
                          + hash(float2(cellCoord) + 7.3) * 0.2);
        // Black background: only living cells get any brightness.
        float3 rgb = hsv2rgb(float3(hue, 1.0, alive));
        uniforms.textures.image.write(float4(rgb, alive), gid);
        return;
    }

    int count = 0;
    float selfState = 0.0;
    float hueSum = 0.0;
    float hueWeight = 0.0;
    float selfHue = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 nc = cellCoord + int2(dx, dy);
            int2 wrapped = ((nc % grid) + grid) % grid;
            int2 samplePix = wrapped * cell + cell / 2;
            float4 smp = uniforms.textures.imagePrev.read(uint2(samplePix));
            float mx = max(smp.r, max(smp.g, smp.b));
            float mn = min(smp.r, min(smp.g, smp.b));
            float d = mx - mn;
            float h = 0.0;
            if (d > 1e-4) {
                if (mx == smp.r)      h = fract((smp.g - smp.b) / d / 6.0);
                else if (mx == smp.g) h = fract(((smp.b - smp.r) / d + 2.0) / 6.0);
                else                  h = fract(((smp.r - smp.g) / d + 4.0) / 6.0);
            }
            if (dx == 0 && dy == 0) {
                selfState = smp.a;
                selfHue = h;
            } else if (smp.a > 0.5) {
                count += 1;
                hueSum += h;
                hueWeight += 1.0;
            }
        }
    }

    bool wasAlive = selfState > 0.5;
    bool nowAlive = wasAlive ? (count == 2 || count == 3)
                             : (count == 3 || count == 6);
    float next = nowAlive ? 1.0 : 0.0;

    // Read this cell's previous color and recover its previous brightness/hue.
    float4 prev = uniforms.textures.imagePrev.read(gid);
    float prevMax = max(prev.r, max(prev.g, prev.b));

    float hue = selfHue;
    if (!wasAlive && nowAlive && hueWeight > 0.0) {
        hue = fract(hueSum / hueWeight + 0.05);
    }
    hue = fract(hue + 0.01);

    // Fading trail decays toward 0, so empty space becomes pure black.
    // Living cells are forced to full brightness.
    float trail = max(prevMax * 0.94, next);
    // Snap tiny residual values to zero so the background is exactly black.
    if (next < 0.5 && trail < 0.02) trail = 0.0;

    // Rainbow color over a black background (value=0 -> black).
    float3 rgb = (trail > 0.0) ? hsv2rgb(float3(hue, 1.0, trail))
                               : float3(0.0);
    uniforms.textures.image.write(float4(rgb, next), gid);
}
