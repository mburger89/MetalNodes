import Foundation
import CoreGraphics
import Metal
import MetalNodesCore

public struct RecordingProgress: Sendable, Equatable {
    /// Frames completed so far (1-based when reported), and the total.
    public let frame: Int
    public let frameCount: Int
    public init(frame: Int, frameCount: Int) { self.frame = frame; self.frameCount = frameCount }
}

/// Renders every frame of a timeline offscreen and hands the pixels to a sink (spec §26.5).
/// One frame in flight, `waitUntilCompleted` per frame: a 240-frame 1080p clip takes seconds,
/// and the simplicity is worth more than the throughput. Never touches the live view.
public actor ExportSession {
    private let queue: MTLCommandQueue
    /// `PreviewProgram` holds `MTLTexture`s and predates `Sendable`, so it cannot cross into the
    /// actor's storage on its own. It is safe here: the caller builds it on the main actor, hands
    /// it over at `init` and keeps its own reference; the session only ever reads it, from its own
    /// executor, and Metal textures are safe to read from any thread.
    private nonisolated(unsafe) let program: PreviewProgram
    private let uniforms: UniformImage
    private var spec: FrameSpec
    private let timeline: Timeline
    private let sink: any FrameSink
    private let meshes: MeshResources
    private let color: MTLTexture
    private let depth: MTLTexture
    private let uniformBuffer: MTLBuffer
    private let readback: MTLBuffer
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    public init(device: MTLDevice, program: PreviewProgram, uniforms: UniformImage, spec: FrameSpec,
                timeline: Timeline, sink: any FrameSink) throws {
        guard let queue = device.makeCommandQueue() else { throw RecordingError.noDevice }
        self.queue = queue
        self.program = program
        self.uniforms = uniforms
        self.spec = spec
        self.timeline = timeline
        self.sink = sink
        self.meshes = MeshResources(device: device)
        // Locals, not the stored properties: a nested function that read `self.width` would
        // capture a half-initialised `self`.
        let w = max(1, Int(spec.size.width.rounded()))
        let h = max(1, Int(spec.size.height.rounded()))
        let stride = w * 4
        width = w
        height = h
        bytesPerRow = stride
        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w,
                                                             height: h, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let color = target(.bgra8Unorm), let depth = target(ShaderCompiler.depthPixelFormat),
              let uniformBuffer = device.makeBuffer(length: max(uniforms.bytes.count, 16), options: .storageModeShared),
              let readback = device.makeBuffer(length: stride * h, options: .storageModeShared)
        else { throw RecordingError.noDevice }
        self.color = color
        self.depth = depth
        self.uniformBuffer = uniformBuffer
        self.readback = readback
    }

    /// Renders and writes every frame. Throws `RecordingError.cancelled` (after abandoning the
    /// sink's output) when the surrounding task is cancelled; rethrows sink errors the same way.
    public func run(progress: @Sendable @escaping (RecordingProgress) -> Void) async throws {
        let count = timeline.frameCount
        try await sink.begin(width: width, height: height, frameRate: timeline.frameRate)
        do {
            for k in 0..<count {
                if Task.isCancelled { throw RecordingError.cancelled }
                // A one-frame timeline with a preset time is a snapshot at that time; every other
                // frame is exactly k / frameRate — the wall clock never gets a say (spec §26.5).
                spec.time = (count == 1 && spec.time != 0) ? spec.time : Float(k) / Float(timeline.frameRate)
                let bytes = try renderFrame()
                try await sink.write(FrameBytes(width: width, height: height, bytesPerRow: bytesPerRow,
                                                bgra: bytes), index: k)
                progress(RecordingProgress(frame: k + 1, frameCount: count))
            }
            try await sink.finish()
        } catch {
            await sink.abandon()
            throw error
        }
    }

    private func renderFrame() throws -> [UInt8] {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
        guard let cmd = queue.makeCommandBuffer() else { throw RecordingError.noDevice }
        guard FrameRenderer.encode(program: program, uniforms: uniforms, spec: spec, into: pass,
                                   uniformBuffer: uniformBuffer, meshes: meshes, command: cmd) else {
            throw RecordingError.writerFailed("the frame could not be encoded")
        }
        guard let blit = cmd.makeBlitCommandEncoder() else { throw RecordingError.noDevice }
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw RecordingError.writerFailed(error.localizedDescription) }
        return Array(UnsafeRawBufferPointer(start: readback.contents(), count: bytesPerRow * height))
    }
}
