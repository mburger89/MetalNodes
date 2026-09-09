import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One rendered frame, read back from the GPU: tightly packed or padded BGRA8, top row first.
public struct FrameBytes: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bgra: [UInt8]
    public init(width: Int, height: Int, bytesPerRow: Int, bgra: [UInt8]) {
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.bgra = bgra
    }
}

/// Where `ExportSession` sends frames (spec §26.5). `begin` before the first `write`; `finish`
/// after the last; `abandon` on cancel or failure removes whatever was written.
public protocol FrameSink: Sendable {
    func begin(width: Int, height: Int, frameRate: Int) async throws
    func write(_ frame: FrameBytes, index: Int) async throws
    func finish() async throws
    func abandon() async
}

/// PNG per frame — `<baseName>_0001.png …` — or, with `singleFileName`, one file (the snapshot).
public final class ImageSequenceSink: FrameSink, @unchecked Sendable {
    private let directory: URL
    private let baseName: String
    private let singleFileName: String?
    private let lock = NSLock()
    private var written: [URL] = []

    public init(directory: URL, baseName: String, singleFileName: String? = nil) {
        self.directory = directory
        self.baseName = baseName
        self.singleFileName = singleFileName
    }

    public func begin(width: Int, height: Int, frameRate: Int) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ frame: FrameBytes, index: Int) async throws {
        guard let image = Self.cgImage(from: frame) else { throw RecordingError.frameConversionFailed(index) }
        let name = singleFileName ?? String(format: "%@_%04d.png", baseName, index + 1)
        let url = directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RecordingError.frameWriteFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RecordingError.frameWriteFailed(url) }
        lock.withLock { written.append(url) }
    }

    public func finish() async throws {}

    public func abandon() async {
        try? FileManager.default.removeItem(at: directory)
    }

    /// BGRA8, top row first, straight alpha — what the readback holds — as a `CGImage`.
    public static func cgImage(from frame: FrameBytes) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue)
        guard let provider = CGDataProvider(data: Data(frame.bgra) as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public enum RecordingError: Error, LocalizedError, Sendable, Equatable {
    case frameConversionFailed(Int)
    case frameWriteFailed(URL)
    case writerFailed(String)
    case cancelled
    case noDevice

    public var errorDescription: String? {
        switch self {
        case .frameConversionFailed(let i): "Frame \(i + 1) could not be converted to an image"
        case .frameWriteFailed(let url): "Could not write \(url.lastPathComponent)"
        case .writerFailed(let why): "The video writer failed: \(why)"
        case .cancelled: "Recording cancelled"
        case .noDevice: "No Metal device is available"
        }
    }
}
