import Foundation
import Metal
import MetalKit
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
    private let startTime = CACurrentMediaTime()
    private var pausedAt: Float?

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
        guard let pipeline = state.pipeline, var image = state.uniforms,
              image.layout == pipeline.shader.layout,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }

        if ring == nil || ring!.size != image.layout.totalSize {
            ring = UniformRing(device: device, size: image.layout.totalSize)
        }

        // Time: wall clock while playing; frozen while paused. On resume, fold the
        // paused span into timeOffset so playback continues from the frozen value
        // with no jump.
        let now = Float(CACurrentMediaTime() - startTime)
        let t: Float
        if state.isPlaying {
            if let p = pausedAt { state.timeOffset = now - p; pausedAt = nil }
            t = now - state.timeOffset
        } else {
            if pausedAt == nil { pausedAt = now - state.timeOffset }
            t = pausedAt!
        }

        image.setReserved(time: t,
                          resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                          mouse: state.mouse)

        inflight.wait()
        let buffer = ring!.next()
        image.bytes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal(); return
        }
        enc.setRenderPipelineState(pipeline.state)
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }
}
