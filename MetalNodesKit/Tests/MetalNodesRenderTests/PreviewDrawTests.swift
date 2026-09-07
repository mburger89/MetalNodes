import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

/// The gap every other render test left open: they build pipelines and never encode a draw, so a
/// pipeline whose attachment formats disagree with the render pass `PreviewView` presents compiles
/// and links perfectly and only dies on the first frame.
///
/// `PreviewView` gives its `MTKView` a `depthStencilPixelFormat` unconditionally, so *every* pass
/// the renderer ever sees carries a depth attachment. A pipeline built without one aborts under
/// Metal's API validation layer — which Xcode's Debug Run action turns on by default:
///
///     -[MTLDebugRenderCommandEncoder setRenderPipelineState:] failed assertion
///     For depth attachment, the render pipeline's pixelFormat (MTLPixelFormatInvalid)
///     does not match the framebuffer's pixelFormat (MTLPixelFormatDepth32Float).
///
/// **Validation is off on a plain `swift test` run, and on under `MTL_DEBUG_LAYER=1 swift test`** —
/// the test binary inherits the environment, and Metal reads the variable when it initialises.
/// Measured on this machine: with the layer *off* the mismatched draw completes with
/// `status == .completed` and `error == nil`, so Metal says nothing at all; with it *on* the
/// assertion above fires and takes the whole test process down (SIGABRT). So
/// `encodesADrawForEveryPipelineKind` is a hard gate only under `MTL_DEBUG_LAYER=1`, and
/// `everyPipelineDeclaresTheViewsDepthAttachment` is the deterministic assertion that stands in for
/// it — and fails on a plain run — when the layer is not enabled.
@Suite struct PreviewDrawTests {
    /// A 2D document and a 3D one — the two pipeline kinds that reach the same `MTKView`.
    private static func shaders() throws -> [(name: String, shader: GeneratedShader)] {
        var material = ShaderDocument()
        material.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(0.2, 0.6, 1, 1))
        g.nodes[terminal.id] = terminal
        g.nodes[color.id] = color
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        material.root = g
        return [("fragment", try ShaderGenerator.generate(ShaderDocument.sample())),
                ("realityKit", try ShaderGenerator.generate(material, target: .realityKit))]
    }

    /// No GPU needed. The invariant the crash violated, stated directly: the pipeline's depth
    /// attachment matches the one `PreviewView` puts on its view, for *both* kinds of program.
    @Test func everyPipelineDeclaresTheViewsDepthAttachment() throws {
        for (name, shader) in try Self.shaders() {
            let desc = ShaderCompiler.pipelineDescriptor(for: shader, vertex: nil, fragment: nil,
                                                         pixelFormat: .bgra8Unorm)
            #expect(desc.depthAttachmentPixelFormat == ShaderCompiler.depthPixelFormat,
                    "\(name): pipeline depth format must match MTKView.depthStencilPixelFormat")
        }
    }

    /// The draw the render tests never encoded, into an offscreen pass shaped exactly like the one
    /// `MTKView` hands `ShaderRenderer` — colour plus a `.depth32Float` attachment — with the same
    /// bindings `ShaderRenderer.draw` makes. Aborts the process under `MTL_DEBUG_LAYER=1` when a
    /// pipeline's attachments disagree; asserts clean completion either way.
    @MainActor
    @Test func encodesADrawForEveryPipelineKind() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let compiler = try ShaderCompiler(device: device)
        let queue = device.makeCommandQueue()!
        let meshes = MeshResources(device: device)

        func target(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 64, height: 64,
                                                             mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let color = target(.bgra8Unorm)
        let depth = target(ShaderCompiler.depthPixelFormat)

        for (name, shader) in try Self.shaders() {
            guard case .success(let pipeline) = await compiler.compile(shader, generation: 1) else {
                Issue.record("\(name): compile failed")
                continue
            }
            var image = UniformImage(layout: shader.layout)
            image.setReserved(time: 0, resolution: SIMD2(64, 64), mouse: .zero)
            let uniforms = device.makeBuffer(length: max(image.bytes.count, 16), options: .storageModeShared)!
            image.bytes.withUnsafeBytes { uniforms.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

            // The same shape `MTKView.currentRenderPassDescriptor` produces for a view whose
            // `depthStencilPixelFormat` is set.
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1.0
            pass.depthAttachment.storeAction = .dontCare

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
            enc.setRenderPipelineState(pipeline.state)          // where validation asserts
            enc.setFragmentBuffer(uniforms, offset: 0, index: 0)
            if shader.target == .realityKit {
                let mesh = try #require(meshes.buffers(for: .sphere))
                var camera = OrbitCamera.default.uniforms(aspect: 1)
                if let ds = pipeline.depthStencilState { enc.setDepthStencilState(ds) }
                enc.setCullMode(.back)
                enc.setFrontFacing(.counterClockwise)
                enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                enc.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
                enc.setVertexBuffer(uniforms, offset: 0, index: 2)
                enc.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint16,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0)
            } else {
                #expect(pipeline.depthStencilState == nil, "\(name): a 2D program must not depth-test")
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
            // `MTLCommandBuffer` is not `Sendable`, so `completed()` is out of reach from here;
            // the completion handler is the same route `ShaderRenderer` takes.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                cmd.addCompletedHandler { _ in c.resume() }
                cmd.commit()
            }
            #expect(cmd.error == nil, "\(name): \(String(describing: cmd.error))")
            #expect(cmd.status == .completed, "\(name): status \(cmd.status.rawValue)")
        }
    }
}
