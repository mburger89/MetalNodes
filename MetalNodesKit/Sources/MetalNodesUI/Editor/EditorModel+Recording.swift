import Foundation
import MetalNodesCore
import MetalNodesRender

/// Playback (spec §26.3). The clock is view state on `preview`; the document owns only the
/// timeline and mode, which `syncClock` copies across whenever they change.
extension EditorModel {
    /// Called after any settings change and on reload: the clock follows the document.
    func syncClock() {
        preview.clock.retarget(document.settings.timeline, mode: document.settings.timeMode)
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
        preview.pausedElapsed = Double(preview.clock.frame) / Double(preview.clock.timeline.frameRate)
        preview.playStartedAt = nil
    }

    public func stepPlayback(by delta: Int) {
        scrub(to: preview.clock.frame + delta)
    }
}
