import Foundation
import Testing
@testable import MetalNodesCore

@Suite struct TimelineTests {
    @Test func defaultsAreFourSecondsAtSixtyLooping() {
        let t = Timeline()
        #expect(t.duration == 4)
        #expect(t.frameRate == 60)
        #expect(t.loops)
        #expect(t.frameCount == 240)
    }

    @Test func frameCountRoundsAndNeverDropsBelowOne() {
        #expect(Timeline(duration: 0.5, frameRate: 30, loops: true).frameCount == 15)
        #expect(Timeline(duration: 0.01, frameRate: 24, loops: true).frameCount == 1)
        #expect(Timeline(duration: 1.0 / 3.0, frameRate: 30, loops: false).frameCount == 10)
    }

    @Test func settingsRoundTripANonDefaultTimeline() throws {
        var s = DocumentSettings()
        s.timeline = Timeline(duration: 2.5, frameRate: 30, loops: false)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: data)
        #expect(back.timeline == s.timeline)
    }

    /// A format-2 document written before M10 has no `timeline` key and must open with the defaults.
    @Test func aMissingTimelineKeyDecodesToTheDefaults() throws {
        let json = #"{"previewSize":[512,512],"timeMode":"wallClock","fastMath":true,"target":{"fragment":{}},"exportName":"x","assets":[],"lightingModel":"lit","liveParameters":[]}"#
        let s = try JSONDecoder().decode(DocumentSettings.self, from: Data(json.utf8))
        #expect(s.timeline == Timeline())
    }
}
