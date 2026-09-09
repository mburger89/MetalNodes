import Foundation
import CoreGraphics
import Metal
import MetalNodesCore

/// Everything one frame needs beyond the program: the reserved uniforms and the 3D view.
public struct FrameSpec: Sendable {
    public var time: Float
    /// Drawable pixels — what the `resolution` uniform and the camera's aspect read.
    public var size: CGSize
    public var mouse: SIMD2<Float>
    public var orbit: OrbitCamera
    public var mesh: PreviewMesh
    public var viewerRange: ClosedRange<Float>

    public init(time: Float, size: CGSize, mouse: SIMD2<Float>, orbit: OrbitCamera,
                mesh: PreviewMesh, viewerRange: ClosedRange<Float>) {
        self.time = time; self.size = size; self.mouse = mouse
        self.orbit = orbit; self.mesh = mesh; self.viewerRange = viewerRange
    }
}

/// Encodes one frame of a preview program into any colour+depth pass (spec §26.4). Owns nothing:
/// the caller supplies the command buffer, the uniform buffer to fill and the mesh cache. The
/// live `MTKView` (`ShaderRenderer`) and the offscreen recorder (`ExportSession`) are its two
/// front ends, so they cannot draw differently.
public enum FrameRenderer {
    /// False when a RealityKit program's mesh buffers are unavailable; nothing was encoded then.
    /// Main-actor isolated because `MeshResources` is — both front ends already draw from there.
    @discardableResult
    @MainActor
    public static func encode(program: PreviewProgram, uniforms image: UniformImage, spec: FrameSpec,
                              into pass: MTLRenderPassDescriptor, uniformBuffer: MTLBuffer,
                              meshes: MeshResources, command: MTLCommandBuffer) -> Bool {
        var image = image
        image.setReserved(time: spec.time,
                          resolution: SIMD2(Float(spec.size.width), Float(spec.size.height)),
                          mouse: spec.mouse)
        image.setViewerRange(spec.viewerRange)
        image.bytes.withUnsafeBytes { uniformBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(program.pipeline.state)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        for (index, texture) in program.textures {
            enc.setFragmentTexture(texture, index: index)
        }

        if program.pipeline.shader.target == .realityKit {
            guard let mesh = meshes.buffers(for: spec.mesh) else {
                enc.endEncoding()
                return false
            }
            var camera = spec.orbit.uniforms(aspect: Float(spec.size.width / max(spec.size.height, 1)))
            if let depth = program.pipeline.depthStencilState { enc.setDepthStencilState(depth) }
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 2)
            enc.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            for (index, texture) in program.textures { enc.setVertexTexture(texture, index: index) }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint16, indexBuffer: mesh.indices, indexBufferOffset: 0)
        } else {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        return true
    }
}
