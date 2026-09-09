import Testing
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@Suite struct EditorClockSyncTests {
    private func model() -> EditorModel {
        EditorModel(document: .sample(), compiler: RecordingCompiler())
    }

    /// A settings change retargets the clock in place: the frame is clamped, play state kept.
    @Test func changingTheTimelineRetargetsTheClock() {
        let m = model()
        m.preview.clock.frame = 100
        m.preview.clock.isPlaying = false
        var s = m.document.settings
        s.timeline = Timeline(duration: 1, frameRate: 30, loops: false)
        s.timeMode = .fixedRate
        m.apply(.setSettings(s))
        #expect(m.preview.clock.timeline == s.timeline)
        #expect(m.preview.clock.mode == .fixedRate)
        #expect(m.preview.clock.frame == 29)
        #expect(!m.preview.clock.isPlaying)
        // The wall-clock bookkeeping is re-based to the clamped frame, so a later Play resumes
        // from where the clock now is rather than from the pre-change elapsed time.
        #expect(m.preview.pausedElapsed == 29.0 / 30.0)
        #expect(m.preview.playStartedAt == nil)
    }

    /// Undo restores the whole document, timeline included — the clock has to follow it back.
    @Test func undoingASettingsChangeSyncsTheClockBack() {
        let m = model()
        m.preview.clock.frame = 100
        var s = m.document.settings
        s.timeline = Timeline(duration: 1, frameRate: 30, loops: false)
        s.timeMode = .fixedRate
        m.apply(.setSettings(s))
        #expect(m.preview.clock.frame == 29)
        m.undo()
        #expect(m.preview.clock.timeline == Timeline())
        #expect(m.preview.clock.mode == .wallClock)
        #expect(m.preview.clock.frame == 29)          // still valid in the restored timeline
    }

    @Test func reloadingADocumentReseedsTheClock() {
        let m = model()
        var doc = ShaderDocument.sample()
        doc.settings.timeline = Timeline(duration: 2, frameRate: 24, loops: true)
        m.reload(package: ShaderPackage(document: doc))
        #expect(m.preview.clock.timeline.frameRate == 24)
        #expect(m.preview.clock.frame == 0)
    }

    @Test func resetAndToggleDriveTheClock() {
        let m = model()
        m.preview.clock.frame = 5
        m.resetPlayback()
        #expect(m.preview.clock.frame == 0)
        m.togglePlayback()
        #expect(!m.preview.clock.isPlaying)
        m.togglePlayback()
        #expect(m.preview.clock.isPlaying)
    }
}
