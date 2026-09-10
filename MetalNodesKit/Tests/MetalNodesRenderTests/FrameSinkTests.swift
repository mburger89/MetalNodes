import Foundation
import ImageIO
import Testing
@testable import MetalNodesRender

@Suite struct FrameSinkTests {
    /// A 2×2 BGRA frame: red, green / blue, half-alpha white.
    private func frame() -> FrameBytes {
        let px: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255], [255, 255, 255, 128]]
        return FrameBytes(width: 2, height: 2, bytesPerRow: 8, bgra: px.flatMap { $0 })
    }

    private func pixels(of url: URL) throws -> [[UInt8]] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var out = [UInt8](repeating: 0, count: 16)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: &out, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        return stride(from: 0, to: 16, by: 4).map { Array(out[$0..<$0 + 4]) }   // RGBA, premultiplied
    }

    @Test func aSequenceWritesNumberedPNGsWithAlpha() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-seq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "clip")
        try await sink.begin(width: 2, height: 2, frameRate: 30, frameCount: 2)
        try await sink.write(frame(), index: 0)
        try await sink.write(frame(), index: 1)
        try await sink.finish()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["clip_0001.png", "clip_0002.png"])
        let px = try pixels(of: dir.appendingPathComponent("clip_0001.png"))
        #expect(px[0] == [255, 0, 0, 255])          // BGRA red came out red
        #expect(px[1] == [0, 255, 0, 255])
        #expect(px[2] == [0, 0, 255, 255])
        #expect(px[3][3] == 128)                    // alpha survived
    }

    @Test func aSnapshotWritesOneNamedFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "x", singleFileName: "shot.png")
        try await sink.begin(width: 2, height: 2, frameRate: 30, frameCount: 1)
        try await sink.write(frame(), index: 0)
        try await sink.finish()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("shot.png").path))
    }

    /// `clip_10000.png` sorts before `clip_9999.png` lexically, which is what importers and Finder
    /// use: the padding has to come from the sequence's length, not from a fixed `%04d`.
    @Test func frameNamesPadToTheSequenceLength() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-pad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "clip")
        try await sink.begin(width: 4, height: 4, frameRate: 60, frameCount: 10_000)
        try await sink.write(FrameBytes(width: 4, height: 4, bytesPerRow: 16, bgra: [UInt8](repeating: 0, count: 64)), index: 0)
        try await sink.write(FrameBytes(width: 4, height: 4, bytesPerRow: 16, bgra: [UInt8](repeating: 0, count: 64)), index: 9_999)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["clip_00001.png", "clip_10000.png"])
    }

    @Test func abandonRemovesWhatWasWritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-abandon-\(UUID().uuidString)")
        let sink = ImageSequenceSink(directory: dir, baseName: "clip")
        try await sink.begin(width: 2, height: 2, frameRate: 30, frameCount: 1)
        try await sink.write(frame(), index: 0)
        await sink.abandon()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
