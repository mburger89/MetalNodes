import Foundation

/// The document's loop (spec §26.2): how long one pass is and how finely it is sampled. Stored
/// with the document, so a file records the same clip on every machine; playback state lives in
/// `TimelineClock`, which is view state.
public struct Timeline: Sendable, Hashable, Codable {
    /// Seconds per loop. Kept > 0 by every writer (the inspector refuses ≤ 0).
    public var duration: Double = 4
    /// One of `frameRates`.
    public var frameRate: Int = 60
    /// Wrap at the end (true) or stop and hold the last frame (false).
    public var loops: Bool = true

    public static let frameRates = [24, 30, 60]

    /// Frames in one pass, rounded to the nearest whole frame and never fewer than one.
    public var frameCount: Int { max(1, Int((duration * Double(frameRate)).rounded())) }

    public init(duration: Double = 4, frameRate: Int = 60, loops: Bool = true) {
        self.duration = duration
        self.frameRate = frameRate
        self.loops = loops
    }
}
