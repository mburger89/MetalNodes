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
    /// The longest loop a document may hold; `EditorModel.setTimeline` refuses past it with a
    /// notice, and the decoder falls back to the default (spec §27.2).
    public static let maxDuration: Double = 3600

    public static func isValidDuration(_ d: Double) -> Bool { d.isFinite && d > 0 && d <= maxDuration }

    /// Frames in one pass, rounded to the nearest whole frame and never fewer than one.
    public var frameCount: Int { Self.frameCount(duration: duration, frameRate: frameRate) }

    /// Bounded in `Double` before the conversion: `Int(Double)` traps outside the `Int` range,
    /// and a timeline is a decoded value (spec §27.2).
    public static func frameCount(duration: Double, frameRate: Int) -> Int {
        let f = (duration * Double(frameRate)).rounded()
        guard f.isFinite else { return 1 }
        return Int(min(max(f, 1), 1e9))
    }

    public init(duration: Double = 4, frameRate: Int = 60, loops: Bool = true) {
        self.duration = duration
        self.frameRate = frameRate
        self.loops = loops
    }

    private enum Keys: String, CodingKey { case duration, frameRate, loops }

    /// Tolerant on purpose: a value no writer produces (the inspector and `setTimeline` both
    /// refuse it) is a hand edit, and the document is still worth opening.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 4
        duration = Self.isValidDuration(d) ? d : 4
        let r = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 60
        frameRate = Self.frameRates.contains(r) ? r : 60
        loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(duration, forKey: .duration)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(loops, forKey: .loops)
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
    /// when looping; with loops off the clock stops at the last frame, exactly as `step()` does, and
    /// the readout stops at the duration (spec §27.5).
    public mutating func seek(elapsed: Double) {
        let safe = elapsed.isFinite ? elapsed : 0
        let scaled = (safe * Double(timeline.frameRate)).rounded(.down)
        let raw = Int(min(max(scaled, -1e9), 1e9))
        if timeline.loops {
            elapsedSeconds = safe
            frame = ((raw % timeline.frameCount) + timeline.frameCount) % timeline.frameCount
        } else if raw >= timeline.frameCount - 1 {
            frame = timeline.frameCount - 1
            elapsedSeconds = timeline.duration
            isPlaying = false
        } else {
            elapsedSeconds = safe
            frame = max(raw, 0)
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

    /// A settings change keeps the *time*, not the frame index: a new frame rate re-scales what an
    /// index means, and a user changing 60 → 24 fps at 1.67 s expects to stay at 1.67 s (spec §27.5).
    public mutating func retarget(_ timeline: Timeline, mode: TimeMode) {
        let t = Double(frame) / Double(self.timeline.frameRate)
        self.timeline = timeline
        self.mode = mode
        frame = min(max(Int((t * Double(timeline.frameRate)).rounded()), 0), timeline.frameCount - 1)
    }
}
