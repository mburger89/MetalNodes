import AVFoundation
import CoreVideo
import Foundation

/// H.264 in an `.mp4`, one frame per timeline frame at `k / frameRate` (spec §26.5).
/// `AVAssetWriter` is not `Sendable`; every access to the writer and its input goes through
/// `queue`, so the sink can be handed to the session's actor and driven from there. The one call
/// made outside the queue is `finishWriting()`, which is awaited on a writer the queue handed
/// back after `markAsFinished` — see `finish()`.
public final class VideoSink: FrameSink, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "MetalNodes.VideoSink")
    // Access to these serialises through `queue` in every method below.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameRate = 60

    public init(url: URL) { self.url = url }

    /// H.264 refuses odd dimensions; round each up to the next even number.
    public static func evenSize(_ size: CGSize) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { let i = Int(v.rounded()); return CGFloat(i % 2 == 0 ? i : i + 1) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    public func begin(width: Int, height: Int, frameRate: Int) async throws {
        try queue.sync {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            guard writer.canAdd(input) else { throw RecordingError.writerFailed("cannot add a video input") }
            writer.add(input)
            guard writer.startWriting() else { throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; self.input = input; self.adaptor = adaptor; self.frameRate = frameRate
        }
    }

    public func write(_ frame: FrameBytes, index: Int) async throws {
        // `isReadyForMoreMediaData` is polled rather than awaited: offline writing at one frame
        // at a time is never far ahead of the encoder. Each poll reads `input` and the writer's
        // status inside `queue.sync`: a writer that has stopped never becomes ready again, so
        // without the status check a failure here would spin the export forever.
        func mustWait() throws -> Bool {
            try queue.sync {
                guard writer?.status == .writing else {
                    throw RecordingError.writerFailed(writer?.error?.localizedDescription ?? "the writer stopped")
                }
                return input?.isReadyForMoreMediaData == false
            }
        }
        while try mustWait() {
            try await Task.sleep(for: .milliseconds(2))
        }
        try queue.sync {
            guard let adaptor, let pool = adaptor.pixelBufferPool else { throw RecordingError.writerFailed("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw RecordingError.writerFailed("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let dstRow = CVPixelBufferGetBytesPerRow(buffer)
            guard let dst = CVPixelBufferGetBaseAddress(buffer) else { throw RecordingError.writerFailed("no base address") }
            frame.bgra.withUnsafeBytes { src in
                for y in 0..<frame.height {
                    memcpy(dst + y * dstRow, src.baseAddress! + y * frame.bytesPerRow, frame.width * 4)
                }
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw RecordingError.writerFailed(writer?.error?.localizedDescription ?? "append")
            }
        }
    }

    public func finish() async throws {
        // `markAsFinished` happens inside `queue.sync`; the writer reference it hands back is
        // then safe to await `finishWriting()` on outside the queue (per the ambiguity note),
        // and `status`/`error` are read back inside `queue.sync` afterward.
        let finishingWriter: AVAssetWriter? = queue.sync {
            guard let writer, let input else { return nil }
            input.markAsFinished()
            return writer
        }
        guard let finishingWriter else { return }
        await finishingWriter.finishWriting()
        try queue.sync {
            if finishingWriter.status != .completed {
                throw RecordingError.writerFailed(finishingWriter.error?.localizedDescription ?? "finishWriting")
            }
        }
    }

    public func abandon() async {
        queue.sync { writer?.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
