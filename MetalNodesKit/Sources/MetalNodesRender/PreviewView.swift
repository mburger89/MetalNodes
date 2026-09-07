import SwiftUI
import MetalKit

/// SwiftUI wrapper around an `MTKView` driven by `ShaderRenderer`.
public struct PreviewView {
    private let state: PreviewState
    private let device: MTLDevice

    public init(state: PreviewState, device: MTLDevice) {
        self.state = state
        self.device = device
    }

    @MainActor
    private func makeView(_ renderer: ShaderRenderer) -> MTKView {
        let v = MTKView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Unconditional, and `ShaderCompiler.pipelineDescriptor` declares the matching attachment on
        // every pipeline it builds: one view outlives many programs, the document's target changes
        // under it, and a dived viewer under `.realityKit` even produces a `.fragment` program, so
        // the pass shape is an invariant of the view rather than something to keep in step with the
        // current program. 2D programs still get no `MTLDepthStencilState`, so nothing is tested or
        // written.
        v.depthStencilPixelFormat = ShaderCompiler.depthPixelFormat
        v.clearDepth = 1.0
        v.preferredFramesPerSecond = 60
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.framebufferOnly = true
        v.delegate = renderer
        return v
    }
}

#if canImport(AppKit)
extension PreviewView: NSViewRepresentable {
    public func makeCoordinator() -> ShaderRenderer { ShaderRenderer(device: device, state: state) }
    public func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    public func updateNSView(_ view: MTKView, context: Context) {}
}
#else
extension PreviewView: UIViewRepresentable {
    public func makeCoordinator() -> ShaderRenderer { ShaderRenderer(device: device, state: state) }
    public func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    public func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
