
import FoundationModels
import Playgrounds
import Metal

struct MetalShaderValidator {
    func compile(source: String) async throws {
        let boilerplateURL = Bundle.main.url(forResource: "ShaderBoilerplate", withExtension: "metal.txt")!
        let boilerplate = try String(contentsOf: boilerplateURL, encoding: .utf8)
        let source = boilerplate.replacingOccurrences(of: "// USER_SHADER_CODE", with: source)
        let device = MTLCreateSystemDefaultDevice()!
        try await device.makeLibrary(source: source, options: .init())
    }
}

extension MetalShaderValidator: Tool {
    var description: String {
        "This tool validates Metal shader code by compiling it with a boilerplate. It ensures that the shader code is valid and can be used in a Metal compute shader context."
    }

    func call(arguments: GenerableShader) async throws -> GenerableShader {
        print(">>>>>>>>>>>>>>>>>>>>>>>")
        try await compile(source: arguments.source)
        return arguments
    }
}

@Generable
struct GenerableShader {
    @Guide(description: "The name of the shader")
    var name: String

    @Guide(description: "The source code of the shader.")
    var source: String
}

extension LanguageModelSession {
    static let metalShaderSession = LanguageModelSession(
        tools: [MetalShaderValidator()],
        instructions: """
You are a helpful assistant that generates Metal shader functions for use in a “shader toy”-style compute shader environment. You are not generating a full Metal shader—just the mainImage function.

Your output must be a single Metal function with the exact signature:

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer)

Constraints:
    •    The function is called per pixel and must return an RGBA color as a float4.
    •    You may only use the provided parameters:
    •    float2 position – the pixel position
    •    float2 resolution – the full texture resolution
    •    float2 mouse – do not use; it does not work
    •    float time – time in seconds since frame 0
    •    float frame – current frame number
    •    texture2d<float, access::read> backbuffer – the previous frame’s output

Notes:
    •    Focus on visual effects using only the allowed inputs.
    •    Avoid boilerplate—your function should be self-contained.
    •    Assume backbuffer.read() works as expected if used.
    •    You can use the following utility functions provided in the shader environment:
    •    rotate2D(float angle) – returns a 2x2 rotation matrix.
    •    rotate3D(float angle, float3 axis) – returns a 3x3 rotation matrix.
    •    fsnoise(float2) / fsnoiseDigits(float2) – simple noise functions.
    •    snoise2D, snoise3D, snoise4D – simplex noise functions for 2D/3D/4D.
    •    hsv(float h, float s, float v) – convert HSV to RGB.
    •    Constants PI and PI2 are available.

Examples:

Return red everywhere:

float4 mainImage(...) {
    return float4(1.0, 0.0, 0.0, 1.0);
}

Draw a red circle:

float4 mainImage(...) {
    float radius = 100.0;
    float2 center = resolution * 0.5;
    float dist = length(position - center);
    return dist < radius ? float4(1, 0, 0, 1) : float4(0, 0, 0, 1);
}

Animated Voronoi cells:

float2 random2(float2 p) {
    return fract(sin(float2(
        dot(p, float2(127.1, 311.7)),
        dot(p, float2(269.5, 183.3))
    )) * 43758.5453);
}

float3 voronoi(float2 p, float time) {
    float2 n = floor(p);
    float2 f = fract(p);
    float minDist1 = 9999.0;
    float minDist2 = 9999.0;
    float cellID = 0.0;
    for(int y = -1; y <= 1; y++) {
        for(int x = -1; x <= 1; x++) {
            float2 neighbor = float2(x, y);
            float2 cellPos = n + neighbor;
            float2 randomOffset = random2(cellPos);
            randomOffset = 0.5 + 0.5 * sin(time * 2.0 + randomOffset * 6.2831);
            float2 diff = neighbor + randomOffset - f;
            float dist = length(diff);
            if(dist < minDist1) {
                minDist2 = minDist1;
                minDist1 = dist;
                cellID = random2(cellPos).x;
            } else if(dist < minDist2) {
                minDist2 = dist;
            }
        }
    }
    return float3(minDist1, minDist2, cellID);
}

float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer) {
    float2 uv = position / resolution.y;
    uv *= 8.0;
    uv += 0.2 * sin(uv.yx * 2.0 + time);
    float3 vor = voronoi(uv, time);
    float d1 = vor.x;
    float d2 = vor.y;
    float id = vor.z;
    float border = smoothstep(0.0, 0.05, d2 - d1);
    float cells = 1.0 - smoothstep(0.0, 0.1, d1);
    float3 cellColor = 0.5 + 0.5 * cos(2.0 * PI * id + float3(0.0, 2.0, 4.0) + time);
    float3 color = mix(cellColor * 0.2, cellColor * (0.5 + 0.5 * cells), border);
    color += 0.1 * (1.0 - d1);
    float highlight = 1.0 - smoothstep(0.0, 0.02, d1);
    color += highlight * 0.5;
    return float4(color, 1.0);
}

Generate functions in this style. Be creative and leverage utility functions and procedural techniques.
""")}

#Playground {
    let session = LanguageModelSession.metalShaderSession
    let prompt = """
        Generate a metal shader that draws a circle.
        """
    let response = try await session.respond(
        to: prompt,
        generating: GenerableShader.self
    )
    print(response.content)
}

