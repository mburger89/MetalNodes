import Foundation
import CoreGraphics
import Metal
import MetalNodesCore
import Observation

/// The pipeline that is drawing and the textures its slots bind, published as one value so the
/// renderer can never see a pipeline with another program's bindings (spec §22.6).
public struct PreviewProgram {
    public let pipeline: CompiledPipeline
    /// Slot index → texture, one entry per `pipeline.shader.textures` slot.
    public let textures: [Int: MTLTexture]
    public init(pipeline: CompiledPipeline, textures: [Int: MTLTexture]) {
        self.pipeline = pipeline; self.textures = textures
    }
}

/// Hand-off between the editor (writes) and the renderer (reads every frame).
@MainActor
@Observable
public final class PreviewState {
    public var program: PreviewProgram?
    /// The live pipeline, for readers that only need it (the preview pane's generation label).
    public var pipeline: CompiledPipeline? { program?.pipeline }
    public var uniforms: UniformImage?
    public var isPlaying = true
    /// Seconds subtracted from wall-clock so "reset time" is cheap.
    public var timeOffset: Float = 0
    /// Set by the UI; the renderer zeroes the clock on the next frame and clears it.
    public var resetRequested = false
    public var mouse = SIMD2<Float>(0, 0)
    public var drawableSize = CGSize(width: 1, height: 1)
    public var lastError: String?
    /// The manual low/high used to normalize a viewed float/int socket into 0...1 (spec §19.3).
    public var viewerRange: ClosedRange<Float> = 0...1
    /// Which mesh the 3D preview draws, and where the camera is (spec §23.5, §23.8). View state:
    /// the editor mirrors these into `EditorViewState`, which is persisted and never undone.
    public var mesh: PreviewMesh = .sphere
    public var orbit: OrbitCamera = .default

    public init() {}
}
