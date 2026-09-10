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
        try await sink.begin(width: 64, height: 64, frameRate: 60, frameCount: 12)
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

    /// With no `colr` atom a player guesses the matrix from the frame size, so the same bytes come
    /// out different in the video, the PNG and the preview. 709 is sRGB's primaries (spec §27.6).
    @Test func theVideoCarriesITU709ColourTags() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 2)
        for k in 0..<2 { try await sink.write(frame(k, width: 64, height: 64), index: k) }
        try await sink.finish()

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        func tag(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        #expect(tag(kCMFormatDescriptionExtension_ColorPrimaries) == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(tag(kCMFormatDescriptionExtension_TransferFunction) == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(tag(kCMFormatDescriptionExtension_YCbCrMatrix) == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
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
        try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 2)
        try await sink.write(frame(0, width: 64, height: 64), index: 0)
        try await sink.finish()
        await #expect(throws: RecordingError.writerFailed("the writer stopped")) {
            try await sink.write(frame(1, width: 64, height: 64), index: 1)
        }
    }

    @Test func abandonRemovesThePartialFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 1)
        try await sink.write(frame(0, width: 64, height: 64), index: 0)
        await sink.abandon()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// H.264 level 6.2: 8192 per edge and 139,264 macroblocks — 35,651,584 pixels. VideoToolbox
    /// accepts every `append` above that and fails only at `finishWriting`, so the bound has to be
    /// stated rather than discovered.
    @Test func theH264CeilingIsLevel6_2() {
        #expect(VideoSink.isSizeSupported(width: 8192, height: 4352))       // 35,651,584 exactly
        #expect(!VideoSink.isSizeSupported(width: 8192, height: 4354))
        #expect(VideoSink.isSizeSupported(width: 8192, height: 8192) == false)
        #expect(!VideoSink.isSizeSupported(width: 8194, height: 16))
        #expect(!VideoSink.isSizeSupported(width: 0, height: 16))
        #expect(VideoSink.isSizeSupported(width: 7680, height: 4320))
    }

    @Test func beginRefusesAnOversizedVideoBeforeAnyFrame() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        let sink = VideoSink(url: url)
        await #expect(throws: RecordingError.sizeUnsupported(CGSize(width: 8192, height: 8192))) {
            try await sink.begin(width: 8192, height: 8192, frameRate: 60, frameCount: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Without `endSession` the writer infers the last sample's duration from the previous delta,
    /// and one sample has none: the file comes out 1/15 s long whatever the frame rate.
    @Test func aOneFrameVideoIsOneFrameLong() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 1)
        try await sink.write(frame(0, width: 64, height: 64), index: 0)
        try await sink.finish()
        let duration = try await AVURLAsset(url: url).load(.duration)
        #expect(abs(duration.seconds - 1.0 / 30.0) < 0.001)
    }

    /// `finishWriting` on a cancelled writer raises an NSException no `catch` can see, and a second
    /// `cancelWriting` does the same: both act only on a writer that is still `.writing`.
    @Test func finishAfterAbandonIsANoOpNotACrash() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 2)
        await sink.abandon()
        await sink.abandon()                                    // idempotent
        await #expect(throws: RecordingError.self) { try await sink.finish() }
    }
}
