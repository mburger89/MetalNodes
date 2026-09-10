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

extension TimelineTests {
    @Test func anAbsurdDurationDecodesToTheDefaultAndNeverTraps() throws {
        for json in [#"{"duration":1e300,"frameRate":60,"loops":true}"#,
                     #"{"duration":-1,"frameRate":60,"loops":true}"#,
                     #"{"duration":0,"frameRate":60,"loops":true}"#,
                     #"{"duration":4000,"frameRate":60,"loops":true}"#] {
            let t = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
            #expect(t.duration == 4, "\(json)")
            #expect(t.frameCount == 240, "\(json)")
        }
        let zero = try JSONDecoder().decode(Timeline.self, from: Data(#"{"duration":2,"frameRate":0,"loops":false}"#.utf8))
        #expect(zero.frameRate == 60)
        #expect(zero.duration == 2)
        let missing = try JSONDecoder().decode(Timeline.self, from: Data("{}".utf8))
        #expect(missing == Timeline())
    }

    @Test func frameCountIsBoundedBeforeTheIntConversion() {
        #expect(Timeline.frameCount(duration: 1e300, frameRate: 60) == 1_000_000_000)
        #expect(Timeline.frameCount(duration: .nan, frameRate: 60) == 1)
        #expect(Timeline.frameCount(duration: 0.001, frameRate: 24) == 1)
        #expect(Timeline.isValidDuration(3600))
        #expect(!Timeline.isValidDuration(3600.5))
        #expect(!Timeline.isValidDuration(0))
        #expect(!Timeline.isValidDuration(.infinity))
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
        // The readout stops at the duration rather than counting past the end (spec §27.5).
        #expect(c.elapsedSeconds == 1)
        #expect(!c.isPlaying)
    }

    @Test func seekingPastTheEndStopsTheClockInWallClockMode() {
        var c = TimelineClock(timeline: Timeline(duration: 1, frameRate: 60, loops: false), mode: .wallClock)
        c.seek(elapsed: 0.5)
        #expect(c.frame == 30)
        #expect(c.isPlaying)
        #expect(c.elapsedSeconds == 0.5)
        c.seek(elapsed: 5)
        #expect(c.frame == 59)
        #expect(!c.isPlaying)
        #expect(c.elapsedSeconds == 1)          // the readout stops at the duration
        c.seek(elapsed: 1e300)                  // bounded before the Int conversion
        #expect(c.frame == 59)
        c.seek(elapsed: .nan)
        #expect(c.frame == 0)
    }

    /// `seek` must stop only on the transition *past* the last frame, exactly as `step()` does —
    /// not on reaching it, which would engage the end state up to 1/fps early.
    @Test func seekingToExactlyTheLastFrameDoesNotYetStopTheClock() {
        var c = TimelineClock(timeline: Timeline(duration: 1, frameRate: 60, loops: false), mode: .wallClock)
        c.seek(elapsed: 0.99)
        #expect(c.frame == 59)
        #expect(c.isPlaying)
        #expect(c.elapsedSeconds == 0.99)
        c.seek(elapsed: 1.0)
        #expect(c.frame == 59)
        #expect(!c.isPlaying)
        #expect(c.elapsedSeconds == 1)
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

    @Test func retargetingPreservesTimeNotTheFrameIndex() {
        var c = TimelineClock(timeline: Timeline(duration: 4, frameRate: 60, loops: true), mode: .fixedRate)
        c.frame = 100                            // 1.667 s
        c.retarget(Timeline(duration: 4, frameRate: 24, loops: true), mode: .fixedRate)
        #expect(c.frame == 40)                   // round(1.667 × 24)
        c.retarget(Timeline(duration: 1, frameRate: 30, loops: false), mode: .fixedRate)
        #expect(c.frame == 29)                   // 1.667 s is past a 1 s clip: clamped to the end
    }
}
