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
