import Foundation
import CoreGraphics
import Observation

/// Hand-off between the editor (writes) and the renderer (reads every frame).
@MainActor
@Observable
public final class PreviewState {
    public var pipeline: CompiledPipeline?
    public var uniforms: UniformImage?
    public var isPlaying = true
    /// Seconds subtracted from wall-clock so "reset time" is cheap.
    public var timeOffset: Float = 0
    public var mouse = SIMD2<Float>(0, 0)
    public var drawableSize = CGSize(width: 1, height: 1)
    public var lastError: String?

    public init() {}
}
