import Metal
import SwiftUI
import Observation

struct ContentView: View {
    @State
    var viewModel = PhosphorViewModel()

    @State
    var snippet = """
    for(float i=-fract(t/.1),j;i++<1e2;o+=(cos((j=round(i+t/.1))*j+vec4(0,1,2,3))+1.)*exp(cos(j*j/.1)/.6)*min(1e3-i/.1+9.,i)/5e4/length((FC.xy-r*.5)/r.y+.05*cos(j*j/F4+vec2(0,5))*sqrt(i)));o=tanh(o*o);

    """

    @State
    var showExpandedSnippet = false

    var body: some View {
        HSplitView {
            PhosphorView(snippet: snippet)
            .overlay {
                if let error = viewModel.error {
                    ContentUnavailableView("Oops", systemImage: "gear", description: Text("\(error.localizedDescription)"))
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .padding()

                }
            }

            Group {
                if showExpandedSnippet {
                    let expandedSnippet = expandSnippet(source: snippet, style: viewModel.snippetStyle)
                    TextEditor(text: .constant(expandedSnippet))
                }
                else {
                    MetalTextEditor(text: $snippet)
                }
            }
            .frame(minWidth: 300)
            .monospaced()
            .toolbar {
                Picker("Snippet Style", selection: $viewModel.snippetStyle) {
                    ForEach(SnippetStyle.allCases, id: \.self) { style in
                        Text(String(describing: style)).tag(style)
                    }
                }
                .labelsVisibility(.visible)

                Toggle("Expanded Snippet", isOn: $showExpandedSnippet)


            }
        }
        .environment(viewModel)
    }
}

struct PhosphorView: View {

    let snippet: String

    @Environment(PhosphorViewModel.self)
    var viewModel

    init(snippet: String) {
        self.snippet = snippet
    }

    var body: some View {
        BareMetalView(device: viewModel.device) { size in
            viewModel.drawableSizeWillChange(size: size)
        }
        draw: { currentRenderPassDescriptor, drawable in
            viewModel.draw(renderPassDescriptor: currentRenderPassDescriptor, drawable: drawable)
        }
        .onChange(of: snippet, initial: true) {
            viewModel.snippet = snippet
        }
    }
}

@Observable
class PhosphorViewModel {
    let device = MTLCreateSystemDefaultDevice()!
    var textures: [MTLTexture] = []
    var snippet: String = "" {
        didSet {
            snippetDidChange()
        }
    }
    var vertexBuffer: MTLBuffer
    let kernelFunction: MTLFunction
    var computePipelineState: MTLComputePipelineState?
    var renderPipelineState: MTLRenderPipelineState?
    var snippetFunctionTable: MTLVisibleFunctionTable?
    var currentTexture: Int = 0
    var commandQueue: MTLCommandQueue
    var frame: Int = 0
    var snippetStyle: SnippetStyle = .twiglGeek {
        didSet {
            snippetDidChange()
        }
    }
    var error: Error?
    var startTime = Date()

    init() {
        let defaultLibrary = device.makeDefaultLibrary()!
        kernelFunction = defaultLibrary.makeFunction(name: "newComputeMain")!

        commandQueue = device.makeCommandQueue()!

        let vertices: [Float] = [
            -1.0, -1.0,  // bottom left
             1.0, -1.0,  // bottom right
             -1.0,  1.0,  // top left
             1.0, -1.0,  // bottom right
             1.0,  1.0,  // top right
             -1.0,  1.0,  // top left
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                              length: vertices.count * MemoryLayout<Float>.size,
                                              options: [])!
        renderPipelineState = try! makeRenderPipeline()


    }

    func snippetDidChange() {
        do {
            print("MAKING PIPELINE")
            (computePipelineState, snippetFunctionTable) = try makeComputePipeline()
            error = nil
        }
        catch {
            print("Error creating compute pipeline: \(error.localizedDescription)")
            self.error = error
            computePipelineState = nil
            snippetFunctionTable = nil
        }

    }

    func drawableSizeWillChange(size: CGSize) {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Int(size.width), height: Int(size.height), mipmapped: false)
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textures = [device.makeTexture(descriptor: textureDescriptor)!, device.makeTexture(descriptor: textureDescriptor)!]
    }

    func draw(renderPassDescriptor: MTLRenderPassDescriptor, drawable: MTLDrawable) {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        compute(commandBuffer: commandBuffer)
        render(renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func compute(commandBuffer: MTLCommandBuffer) {
        guard textures.count >= 2 else {
            print("Not enough textures for buffering")
            return
        }

        let textureA = textures[currentTexture]
        let textureB = textures[(currentTexture + 1) % textures.count]

        guard let computePipelineState else {
            print("Compute pipeline state not ready")
            return
        }

        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        computeEncoder.setComputePipelineState(computePipelineState)

        computeEncoder.setTexture(textureA, index: 0) // Output texture
        computeEncoder.setTexture(textureB, index: 1) // Input texture

        struct Uniforms {
            var time: Float
            var frame: Float
            var resolution: SIMD2<Float>
            var mouse: SIMD2<Float>
        }

        var uniforms = Uniforms(
            time: Float(Date().timeIntervalSince(startTime)),
            frame: Float(frame),
            resolution: [Float(textureA.width), Float(textureA.height)],
            mouse: [0.5, 0.5]
        )
        computeEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        computeEncoder.setVisibleFunctionTable(snippetFunctionTable, bufferIndex: 1)
        let threads = MTLSize(width: textureA.width, height: textureA.height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        computeEncoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()
    }

    func render(renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) {
        guard let renderPipelineState else {
            print("Render pipeline state not ready")
            return
        }
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(textures[currentTexture], index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
    }

    func makeComputePipeline() throws -> (MTLComputePipelineState, MTLVisibleFunctionTable) {

        let snippet = expandSnippet(source: snippet, style: snippetStyle)

        let snippetFunction = try SnippetCompiler().compileSnippet(snippet: snippet)

        let pipelineDescriptor = MTLComputePipelineDescriptor()
        pipelineDescriptor.computeFunction = kernelFunction
        let linkedFunctions = MTLLinkedFunctions()
        linkedFunctions.functions = [snippetFunction]
        pipelineDescriptor.linkedFunctions = linkedFunctions

        let (pipeline, reflection) = try device.makeComputePipelineState(descriptor: pipelineDescriptor, options: [.bindingInfo])

        let functionTableDescriptor = MTLVisibleFunctionTableDescriptor()
        functionTableDescriptor.functionCount = 1
        let functionTable = pipeline.makeVisibleFunctionTable(descriptor: functionTableDescriptor)!
        let functionHandle = pipeline.functionHandle(function: snippetFunction)!
        functionTable.setFunction(functionHandle, index:0)

        return (pipeline, functionTable)
    }

    func makeRenderPipeline() throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()!
        // Create render pipeline
        let vertexFunction = library.makeFunction(name: "vertexShader")!
        let fragmentFunction = library.makeFunction(name: "fragmentShader")!

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}




struct SnippetCompiler {
    func compileSnippet(snippet: String) throws -> MTLFunction {


        let device = MTLCreateSystemDefaultDevice()!
        let snippetLibrary = try device.makeLibrary(source: snippet, options: nil)
        let functionDescriptor = MTLFunctionDescriptor()
        functionDescriptor.name = "snippet"

        let snippetFunction = try snippetLibrary.makeFunction(descriptor: functionDescriptor)

//        let inputNodes = [
//            MTLFunctionStitchingInputNode(argumentIndex: 0),
//            MTLFunctionStitchingInputNode(argumentIndex: 1),
//            MTLFunctionStitchingInputNode(argumentIndex: 2),
//            MTLFunctionStitchingInputNode(argumentIndex: 3),
//            MTLFunctionStitchingInputNode(argumentIndex: 4),
//            MTLFunctionStitchingInputNode(argumentIndex: 5),
//        ]
//        let functionNode = MTLFunctionStitchingFunctionNode(name: "snippet", arguments: inputNodes, controlDependencies: [])
//        let graph = MTLFunctionStitchingGraph(functionName: "mygraph", nodes: [functionNode], outputNode: nil, attributes: [])
//        let stitchedLibraryDescriptor = MTLStitchedLibraryDescriptor()
//        stitchedLibraryDescriptor.functions = [snippetFunction]
//        stitchedLibraryDescriptor.functionGraphs = [graph]
//        let stitchedLibrary = try device.makeLibrary(stitchedDescriptor: stitchedLibraryDescriptor)
//        let stitchedFunction = try stitchedLibrary.makeFunction(name: "mygraph")!
//
//        print(stitchedFunction.name, stitchedFunction.functionType.rawValue)

        return snippetFunction
    }

}

enum SnippetStyle: CaseIterable {
    case raw
    case original
    case twiglGeek
}

func expandSnippet(source: String, style: SnippetStyle) -> String {

    let supportURL = Bundle.main.url(forResource: "Support", withExtension: "h")!
    let supportCode = try! String(contentsOf: supportURL, encoding: .utf8)


//
//    for(float i=-fract(t/.1),j;i++<1e2;o+=(cos((j=round(i+t/.1))*j+vec4(0,1,2,3))+1.)*exp(cos(j*j/.1)/.6)*min(1e3-i/.1+9.,i)/5e4/length((FC.xy-r*.5)/r.y+.05*cos(j*j/F4+vec2(0,5))*sqrt(i)));o=tanh(o*o);


    switch style {
    case .raw:
        return """
            \(supportCode)
            \(source)
        """
    case .original:
        return """
            \(supportCode)

            #import <metal_stdlib>

            using namespace metal;

            [[stitchable]] \(source)
        """
    case .twiglGeek:
        return """
        \(supportCode)

        #import <metal_stdlib>

        using namespace metal;

        [[stitchable]] float4 snippet(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer) {
            auto r = resolution;
            auto m = mouse;
            auto t = time;
            auto f = frame;
            auto b = backbuffer;
            auto FC = position;
            float4 o = float4(0, 0, 0, 1);
            // START SNIPPET
            \(source)    
            // END SNIPPET
            return o;
        }    
        """
    }
}

//for(float i=-fract(t/.1),j;i++<1e2;o+=(cos((j=round(i+t/.1))*j+vec4(0,1,2,3))+1.)*exp(cos(j*j/.1)/.6)*min(1e3-i/.1+9.,i)/5e4/length((FC.xy-r*.5)/r.y+.05*cos(j*j/F4+vec2(0,5))*sqrt(i)));o=tanh(o*o);

struct Snipper {
    var source: String
    var style: SnippetStyle

    var expandedSource: String {
        return ""
    }
}

