import Foundation
import Metal
import MetalKit
import MetalNodesCore
import QuartzCore

/// Draws the current pipeline as a fullscreen triangle. Runs on the main actor —
/// `MTKView` calls its delegate on the main thread.
@MainActor
public final class ShaderRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let state: PreviewState
    private var ring: UniformRing?
    private let inflight = DispatchSemaphore(value: 3)
    private lazy var meshes = MeshResources(device: device)

    public init(device: MTLDevice, state: PreviewState) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.state = state
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        state.drawableSize = size
    }

    public func draw(in view: MTKView) {
        guard let program = state.program, var image = state.uniforms,
              image.layout == program.pipeline.shader.layout,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }

        if ring == nil || ring!.size != image.layout.totalSize {
            ring = UniformRing(device: device, size: image.layout.totalSize)
        }

        // Time comes from the clock (spec §26.3). Wall clock: elapsed play time places it —
        // pausing freezes `pausedElapsed`, resuming starts a new run from there, so there is no
        // jump. Fixed rate: exactly one frame per draw while playing, so the same draws always
        // produce the same `time` values — what makes recording frame-exact.
        switch state.clock.mode {
        case .wallClock:
            if state.clock.isPlaying {
                let now = CACurrentMediaTime()
                let started = state.playStartedAt ?? now
                state.playStartedAt = started
                state.clock.seek(elapsed: state.pausedElapsed + (now - started))
            } else if let started = state.playStartedAt {
                state.pausedElapsed += CACurrentMediaTime() - started
                state.playStartedAt = nil
            }
        case .fixedRate:
            state.playStartedAt = nil
            state.clock.step()
        }
        let t = state.clock.time

        image.setReserved(time: t,
                          resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                          mouse: state.mouse)
        image.setViewerRange(state.viewerRange)

        inflight.wait()
        let buffer = ring!.next()
        image.bytes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal(); return
        }
        enc.setRenderPipelineState(program.pipeline.state)
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        for (index, texture) in program.textures {
            enc.setFragmentTexture(texture, index: index)
        }

        if program.pipeline.shader.target == .realityKit {
            guard let mesh = meshes.buffers(for: state.mesh) else {
                enc.endEncoding(); inflight.signal(); return
            }
            var camera = state.orbit.uniforms(aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
            if let depth = program.pipeline.depthStencilState { enc.setDepthStencilState(depth) }
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            enc.setVertexBuffer(buffer, offset: 0, index: 2)
            enc.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            for (index, texture) in program.textures { enc.setVertexTexture(texture, index: index) }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint16, indexBuffer: mesh.indices, indexBufferOffset: 0)
        } else {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }
}
