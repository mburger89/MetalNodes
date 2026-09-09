import AVFoundation
import Foundation
import Testing
@testable import MetalNodesRender

@Suite struct VideoSinkTests {
    private func frame(_ k: Int, width: Int, height: Int) -> FrameBytes {
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        for p in stride(from: 0, to: bgra.count, by: 4) { bgra[p + 2] = UInt8(min(255, k * 20)); bgra[p + 3] = 255 }
        return FrameBytes(width: width, height: height, bytesPerRow: width * 4, bgra: bgra)
    }

    @Test func twelveFramesAtSixtyMakeAFifthOfASecondOfH264() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 60)
        for k in 0..<12 { try await sink.write(frame(k, width: 64, height: 64), index: k) }
        try await sink.finish()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 0.2) < 1.0 / 60.0)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.nominalFrameRate)
        #expect(abs(Double(rate) - 60) < 0.5)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 64))
    }

    @Test func oddSizesAreRoundedUpToEven() {
        #expect(VideoSink.evenSize(CGSize(width: 63, height: 65)) == CGSize(width: 64, height: 66))
        #expect(VideoSink.evenSize(CGSize(width: 64, height: 64)) == CGSize(width: 64, height: 64))
    }

    /// `write` waits for `isReadyForMoreMediaData`, and a writer that has stopped never becomes
    /// ready again: without the status check the poll is an infinite loop. A finished writer is
    /// the cheapest way to reach that state — the error names it rather than the append failing.
    @Test(.timeLimit(.minutes(1)))
    func writingAfterTheWriterHasStoppedThrowsRatherThanSpinning() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30)
        try await sink.write(frame(0, width: 64, height: 64), index: 0)
        try await sink.finish()
        await #expect(throws: RecordingError.writerFailed("the writer stopped")) {
            try await sink.write(frame(1, width: 64, height: 64), index: 1)
        }
    }

    @Test func abandonRemovesThePartialFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30)
        try await sink.write(frame(0, width: 64, height: 64), index: 0)
        await sink.abandon()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
