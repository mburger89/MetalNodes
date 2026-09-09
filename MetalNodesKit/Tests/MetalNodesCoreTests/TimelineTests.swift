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

@Suite struct TimelineClockTests {
    private func clock(_ duration: Double = 1, fps: Int = 30, loops: Bool = true, mode: TimeMode = .fixedRate) -> TimelineClock {
        TimelineClock(timeline: Timeline(duration: duration, frameRate: fps, loops: loops), mode: mode)
    }

    @Test func timeIsFrameOverFrameRateExactly() {
        for fps in Timeline.frameRates {
            var c = clock(1, fps: fps)
            c.frame = 7
            #expect(c.time == Float(7) / Float(fps))
        }
    }

    @Test func steppingWrapsWhenLooping() {
        var c = clock(0.1, fps: 30)                    // 3 frames
        c.step(); c.step()
        #expect(c.frame == 2)
        c.step()
        #expect(c.frame == 0)
        #expect(c.isPlaying)
    }

    @Test func steppingStopsAndHoldsWhenNotLooping() {
        var c = clock(0.1, fps: 30, loops: false)      // 3 frames
        c.step(); c.step(); c.step()
        #expect(c.frame == 2)
        #expect(!c.isPlaying)
        c.step()                                        // stays put while stopped
        #expect(c.frame == 2)
    }

    @Test func seekingWrapsElapsedTimeModuloTheLoop() {
        var c = clock(1, fps: 30)
        c.seek(elapsed: 2.5)
        #expect(c.frame == 15)
        #expect(c.elapsedSeconds == 2.5)
    }

    @Test func seekingPastTheEndWithoutLoopingPinsTheLastFrame() {
        var c = clock(1, fps: 30, loops: false)
        c.seek(elapsed: 2.5)
        #expect(c.frame == 29)
        #expect(c.elapsedSeconds == 2.5)                // the readout keeps counting
    }

    @Test func scrubbingClampsAndPauses() {
        var c = clock(1, fps: 30)
        c.scrub(to: 99)
        #expect(c.frame == 29)
        #expect(!c.isPlaying)
        c.scrub(to: -3)
        #expect(c.frame == 0)
    }

    @Test func resetGoesToFrameZeroAndKeepsPlaying() {
        var c = clock(1, fps: 30)
        c.frame = 12
        c.reset()
        #expect(c.frame == 0)
        #expect(c.isPlaying)
    }

    @Test func retargetingClampsTheFrameAndKeepsTheRest() {
        var c = clock(4, fps: 60)
        c.frame = 200
        c.isPlaying = false
        c.retarget(Timeline(duration: 1, frameRate: 60, loops: true), mode: .wallClock)
        #expect(c.frame == 59)
        #expect(!c.isPlaying)
        #expect(c.mode == .wallClock)
    }
}
