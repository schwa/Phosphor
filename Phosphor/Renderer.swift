import MetalKit

struct Uniforms {
    var time: Float = 0
    var frame: Float = 0
    var resolution: SIMD2<Float> = .zero
    var mouse: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var computePipelineState: MTLComputePipelineState
    let renderPipelineState: MTLRenderPipelineState
    
    private var dynamicLibrary: MTLDynamicLibrary?
    private var currentShaderSource: String = ""
    private var shaderBoilerplate: String = ""
    
    var textureA: MTLTexture?
    var textureB: MTLTexture?
    var currentTextureIndex = 0
    let vertexBuffer: MTLBuffer
    
    var uniforms = Uniforms()
    var startTime: TimeInterval = 0
    
    override init() {
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        
        // Create a temporary compute pipeline - will be replaced when shader is loaded
        let library = device.makeDefaultLibrary()!
        // We need a dummy compute function to start with
        let dummySource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void computeMain(texture2d<float, access::write> outTexture [[texture(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
            outTexture.write(float4(0.0), gid);
        }
        """
        
        let dummyLibrary = try! device.makeLibrary(source: dummySource, options: nil)
        let computeFunction = dummyLibrary.makeFunction(name: "computeMain")!
        self.computePipelineState = try! device.makeComputePipelineState(function: computeFunction)
        
        // Create render pipeline
        let vertexFunction = library.makeFunction(name: "vertexShader")!
        let fragmentFunction = library.makeFunction(name: "fragmentShader")!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        self.renderPipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        // Create vertex buffer for fullscreen quad
        let vertices: [Float] = [
            -1.0, -1.0,  // bottom left
             1.0, -1.0,  // bottom right
            -1.0,  1.0,  // top left
             1.0, -1.0,  // bottom right
             1.0,  1.0,  // top right
            -1.0,  1.0,  // top left
        ]
        self.vertexBuffer = device.makeBuffer(bytes: vertices, 
                                            length: vertices.count * MemoryLayout<Float>.size,
                                            options: [])!
        
        super.init()
        
        // Load shader boilerplate
        if let url = Bundle.main.url(forResource: "ShaderBoilerplate.metal", withExtension: "txt"),
           let content = try? String(contentsOf: url) {
            shaderBoilerplate = content
        }
        
        // Initialize start time
        startTime = CACurrentMediaTime()
    }
    
    func updateShaderSource(_ source: String, completion: @escaping (String?) -> Void) {
        guard source != currentShaderSource else { 
            // Don't call completion if source hasn't changed
            return 
        }
        currentShaderSource = source
        
        // Replace the placeholder in boilerplate with user shader code
        let completeSource = shaderBoilerplate.replacingOccurrences(of: "// USER_SHADER_CODE", with: source)
        
        do {
            // Compile the shader source
            let options = MTLCompileOptions()
            options.languageVersion = .version3_0
            
            let library = try device.makeLibrary(source: completeSource, options: options)
            
            // Create new compute pipeline
            guard let computeFunction = library.makeFunction(name: "computeMain") else {
                let errorMessage = "Failed to find computeMain function"
                print(errorMessage)
                completion(errorMessage)
                return
            }
            
            let newPipelineState = try device.makeComputePipelineState(function: computeFunction)
            computePipelineState = newPipelineState
            
            print("Shader compiled successfully")
            completion(nil)
        } catch {
            let errorMessage = "Shader compilation error:\n\(error.localizedDescription)"
            print(errorMessage)
            completion(errorMessage)
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Create two textures for double buffering
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .rgba32Float
        textureDescriptor.width = Int(size.width)
        textureDescriptor.height = Int(size.height)
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        textureA = device.makeTexture(descriptor: textureDescriptor)
        textureB = device.makeTexture(descriptor: textureDescriptor)
        
        // Update resolution in uniforms
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let textureA = textureA,
              let textureB = textureB else { return }
        
        // Update time and frame
        uniforms.time = Float(CACurrentMediaTime() - startTime)
        uniforms.frame += 1
        
        // Determine current and previous textures
        let currentTexture = currentTextureIndex == 0 ? textureA : textureB
        let previousTexture = currentTextureIndex == 0 ? textureB : textureA
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        // Compute pass - process with previous texture and write to current
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(currentTexture, index: 0) // Output texture
        computeEncoder.setTexture(previousTexture, index: 1) // Previous frame texture
        computeEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (currentTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (currentTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        // Render pass - draw current texture to screen
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(currentTexture, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        // Swap texture index for next frame
        currentTextureIndex = 1 - currentTextureIndex
    }
}
