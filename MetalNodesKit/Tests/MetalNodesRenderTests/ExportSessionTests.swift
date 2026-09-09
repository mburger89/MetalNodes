import CoreGraphics
import Foundation
import ImageIO
import Metal
import Synchronization
import Testing
import MetalNodesCore
@testable import MetalNodesRender

/// `ExportSession` renders a timeline offscreen. The point of these tests is that the frames it
/// writes are *frame-exact* — frame `k` is the shader at `k / frameRate`, never at whatever the
/// wall clock said — and that a cancelled export leaves nothing behind.
@Suite struct ExportSessionTests {
    /// A fragment document whose colour is `float4(time, 0, 0, 1)`: an Expression fed by Time.
    /// Read back, the red byte *is* the `time` uniform, so a written frame proves its own time.
    static func timeDocument() -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        let expr = NodeInstance(id: NodeID(), kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("float4(t, 0.0, 0.0, 1.0)"),
                                         "type": .enumCase("color")])
        for n in [terminal, time, expr] { g.nodes[n.id] = n }
        g.inputs[SocketRef(expr.id, "t")] = SocketRef(time.id, "time")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        return doc
    }

    /// The red byte of the top-left pixel of a written PNG.
    static func redChannel(of url: URL) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return out[0]
    }

    private static func compiled(_ device: MTLDevice) async throws -> (GeneratedShader, CompiledPipeline)? {
        let shader = try ShaderGenerator.generate(timeDocument())
        let compiler = try ShaderCompiler(device: device)
        guard case .success(let pipeline) = await compiler.compile(shader, generation: 1, fastMath: true) else {
            Issue.record("compile failed")
            return nil
        }
        return (shader, pipeline)
    }

    @MainActor
    @Test func framesAreExactlyKOverFrameRate() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        guard let (shader, pipeline) = try await Self.compiled(device) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "t")
        let spec = FrameSpec(time: 0, size: CGSize(width: 8, height: 8), mouse: SIMD2(4, 4),
                             orbit: .default, mesh: .sphere, viewerRange: 0...1)
        // 3 frames at 60 fps: t = 0, 1/60, 2/60. The pipeline writes to a `.bgra8Unorm` target and
        // the sink tags the bytes sRGB without converting them, so the stored byte is
        // round(t * 255) with no colour management: 0, 4, 9 (±1 for the GPU's own rounding).
        let session = try ExportSession(device: device, program: PreviewProgram(pipeline: pipeline, textures: [:]),
                                        uniforms: UniformImage(layout: shader.layout), spec: spec,
                                        timeline: Timeline(duration: 0.05, frameRate: 60, loops: true), sink: sink)
        let seen = Mutex<[RecordingProgress]>([])
        try await session.run { p in seen.withLock { $0.append(p) } }
        let reports = seen.withLock { $0 }
        #expect(reports.map(\.frame) == [1, 2, 3])
        #expect(reports.allSatisfy { $0.frameCount == 3 })
        for k in 0..<3 {
            let red = try Self.redChannel(of: dir.appendingPathComponent(String(format: "t_%04d.png", k + 1)))
            let expected = Int((Double(k) / 60.0 * 255).rounded())
            #expect(abs(Int(red) - expected) <= 1, "frame \(k): red \(red), expected \(expected)")
        }
    }

    /// A one-frame timeline with a preset time is the snapshot case: `spec.time` wins over `0/fps`.
    @MainActor
    @Test func aSingleFrameTimelineHonoursThePresetTime() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        guard let (shader, pipeline) = try await Self.compiled(device) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "s", singleFileName: "snap.png")
        let spec = FrameSpec(time: 0.5, size: CGSize(width: 8, height: 8), mouse: .zero,
                             orbit: .default, mesh: .sphere, viewerRange: 0...1)
        let session = try ExportSession(device: device, program: PreviewProgram(pipeline: pipeline, textures: [:]),
                                        uniforms: UniformImage(layout: shader.layout), spec: spec,
                                        timeline: Timeline(duration: 1.0 / 60.0, frameRate: 60, loops: false),
                                        sink: sink)
        let seen = Mutex<[RecordingProgress]>([])
        try await session.run { p in seen.withLock { $0.append(p) } }
        #expect(seen.withLock { $0 } == [RecordingProgress(frame: 1, frameCount: 1)])
        let red = try Self.redChannel(of: dir.appendingPathComponent("snap.png"))
        #expect(abs(Int(red) - 128) <= 1, "snapshot red \(red), expected 128 for t = 0.5")
    }

    @MainActor
    @Test func cancellationAbandonsTheOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        guard let (shader, pipeline) = try await Self.compiled(device) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "t")
        let spec = FrameSpec(time: 0, size: CGSize(width: 8, height: 8), mouse: .zero,
                             orbit: .default, mesh: .sphere, viewerRange: 0...1)
        let session = try ExportSession(device: device, program: PreviewProgram(pipeline: pipeline, textures: [:]),
                                        uniforms: UniformImage(layout: shader.layout), spec: spec,
                                        timeline: Timeline(duration: 10, frameRate: 60, loops: true), sink: sink)
        let task = Task {
            try await session.run { p in if p.frame == 3 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        await #expect(throws: RecordingError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "a cancelled export must leave nothing behind")
    }
}
