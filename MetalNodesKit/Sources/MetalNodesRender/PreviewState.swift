import Foundation
import CoreGraphics
import Metal
import Observation

/// Hand-off between the editor (writes) and the renderer (reads every frame).
@MainActor
@Observable
public final class PreviewState {
    public var pipeline: CompiledPipeline?
    public var uniforms: UniformImage?
    /// Slot index → texture, rebuilt by the editor whenever the pipeline or the texture
    /// manifest changes (spec §21.2). The renderer binds every entry each frame.
    public var textures: [Int: MTLTexture] = [:]
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

    public init() {}
}
