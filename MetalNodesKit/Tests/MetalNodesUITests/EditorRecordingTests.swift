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
