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

/// Playback over a `Timeline` (spec §26.3). A pure value: the renderer advances it once per drawn
/// frame in `.fixedRate` mode and places it by elapsed real time in `.wallClock` mode; the preview
/// controls scrub and reset it. Nothing here touches Metal, so every transition is unit-tested.
public struct TimelineClock: Sendable, Equatable {
    public var timeline: Timeline
    public var mode: TimeMode
    /// 0 ..< timeline.frameCount. Past the end with `loops` off the clock holds the last frame.
    public var frame: Int = 0
    public var isPlaying = true
    /// Wall-clock seconds of play the last `seek(elapsed:)` saw — the readout when the loop is
    /// off and time has run past the end.
    public private(set) var elapsedSeconds: Double = 0

    public init(timeline: Timeline, mode: TimeMode) {
        self.timeline = timeline
        self.mode = mode
    }

    /// The `time` uniform: frame over frame rate, exactly.
    public var time: Float { Float(frame) / Float(timeline.frameRate) }

    /// Fixed rate: one frame forward. At the end, wrap when looping, else stop and hold.
    public mutating func step() {
        guard isPlaying else { return }
        let next = frame + 1
        if next < timeline.frameCount {
            frame = next
        } else if timeline.loops {
            frame = 0
        } else {
            frame = timeline.frameCount - 1
            isPlaying = false
        }
    }

    /// Wall clock: place the clock at `elapsed` seconds of play. Wraps modulo the loop's duration
    /// when looping; with loops off the frame pins at the end while `elapsedSeconds` keeps counting.
    public mutating func seek(elapsed: Double) {
        elapsedSeconds = elapsed
        let raw = Int((elapsed * Double(timeline.frameRate)).rounded(.down))
        if timeline.loops {
            frame = ((raw % timeline.frameCount) + timeline.frameCount) % timeline.frameCount
        } else {
            frame = min(max(raw, 0), timeline.frameCount - 1)
        }
    }

    /// Scrubbing: sets the frame (clamped) and pauses.
    public mutating func scrub(to newFrame: Int) {
        frame = min(max(newFrame, 0), timeline.frameCount - 1)
        isPlaying = false
    }

    public mutating func reset() {
        frame = 0
        elapsedSeconds = 0
    }

    /// A settings change: keep the position where it can be kept.
    public mutating func retarget(_ timeline: Timeline, mode: TimeMode) {
        self.timeline = timeline
        self.mode = mode
        frame = min(frame, timeline.frameCount - 1)
    }
}
