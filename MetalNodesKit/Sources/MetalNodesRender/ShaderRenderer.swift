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
        guard let program = state.program, let image = state.uniforms,
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
            // Both writes are guarded: `PreviewState` is observable, and assigning the same value
            // every draw would invalidate every view reading the clock at refresh rate even while
            // playback is paused. `step()` is already a no-op when paused — the guard is about not
            // writing to the observable property.
            if state.playStartedAt != nil { state.playStartedAt = nil }
            if state.clock.isPlaying { state.clock.step() }
        }
        let t = state.clock.time

        let spec = FrameSpec(time: t,
                             size: view.drawableSize, mouse: state.mouse,
                             orbit: state.orbit, mesh: state.mesh, viewerRange: state.viewerRange)
        inflight.wait()
        let buffer = ring!.next()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        guard FrameRenderer.encode(program: program, uniforms: image, spec: spec, into: pass,
                                   uniformBuffer: buffer, meshes: meshes, command: cmd) else {
            inflight.signal(); return
        }
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }
}
