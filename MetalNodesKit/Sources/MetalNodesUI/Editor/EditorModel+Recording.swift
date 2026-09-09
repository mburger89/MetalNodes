import Foundation
import MetalNodesCore
import MetalNodesRender

/// Playback (spec §26.3). The clock is view state on `preview`; the document owns only the
/// timeline and mode, which `syncClock` copies across whenever they change.
extension EditorModel {
    /// Called after any settings change, on undo/redo and on reload: the clock follows the
    /// document (spec §26.3). `retarget` can clamp the frame into a shorter timeline, and a new
    /// frame rate re-scales what a frame index means, so the wall-clock bookkeeping is re-based to
    /// the frame the clock actually holds — exactly as `scrub(to:)` does — otherwise the next Play
    /// would resume from the elapsed time of the *old* timeline and jump.
    func syncClock() {
        preview.clock.retarget(document.settings.timeline, mode: document.settings.timeMode)
        rebaseWallClock()
    }

    /// Point `pausedElapsed` at the clock's current frame and end the running play interval, so
    /// the renderer's `.wallClock` branch starts its next run from here.
    private func rebaseWallClock() {
        preview.pausedElapsed = Double(preview.clock.frame) / Double(preview.clock.timeline.frameRate)
        preview.playStartedAt = nil
    }

    public func resetPlayback() {
        preview.clock.reset()
        preview.pausedElapsed = 0
        preview.playStartedAt = nil
    }

    public func togglePlayback() {
        preview.clock.isPlaying.toggle()
    }

    /// The scrubber: pauses and moves. The wall-clock bookkeeping is re-based so a later Play
    /// continues from the scrubbed frame rather than snapping back.
    public func scrub(to frame: Int) {
        preview.clock.scrub(to: frame)
        rebaseWallClock()
    }

    public func stepPlayback(by delta: Int) {
        scrub(to: preview.clock.frame + delta)
    }

    /// The Timeline block's edits (spec §26.2): one settings change, undoable as "Change Value".
    public func setTimeline(_ timeline: Timeline) {
        guard timeline.duration > 0 else {
            showNotice("Duration must be greater than zero")
            return
        }
        var s = document.settings
        s.timeline = timeline
        apply(.setSettings(s))
    }
}
