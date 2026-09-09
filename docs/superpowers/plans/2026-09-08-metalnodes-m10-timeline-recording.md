# MetalNodes M10 — Timeline and Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scrubable fixed-rate timeline with a frame counter in the preview, and recording of the document's shader as an H.264 video, a PNG image sequence, or a PNG snapshot, rendered offscreen frame by frame at a size chosen per export.

**Architecture:** The timeline (duration, frame rate, loop) is an optional document setting; a pure `TimelineClock` in Core turns it into frames and time and gives the long-dead `.fixedRate` mode its meaning. The encode step of `ShaderRenderer.draw(in:)` moves into `FrameRenderer.encode(...)`, one function with two front ends: the live `MTKView` and an offscreen `ExportSession` actor that renders frame k at `k / fps`, reads the pixels back, and hands them to a `FrameSink` (`VideoSink` on `AVAssetWriter`, `ImageSequenceSink` on ImageIO). The session always renders to a temporary location; a platform `RecordingDestination` then places the result (save/open panels on the Mac, `fileExporter` on the iPad), so rendering never needs a security-scoped URL.

**Tech Stack:** Swift 6.4 strict concurrency, SwiftUI + AppKit/UIKit, Metal/MetalKit, AVFoundation (`AVAssetWriter`), ImageIO/CoreGraphics, Swift Testing; Xcode 26.6 for `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` §26 (M10 addendum). §26 wins wherever it and §10/§21 differ.

## Global Constraints

- **The document format stays at version 2.** `timeline` and `lastExportSize` are optional keys with defaults; `FormatCorpusTests` passes untouched (settings never reach MSL).
- **The user's stored text and graph are never modified by playback or recording.** Scrubbing, playing and exporting touch `PreviewState` and `EditorViewState` only; the one document change is the Timeline block's edits, each a `DocumentChange.setSettings`.
- **One encode path.** After Task 4, no file other than `FrameRenderer.swift` calls `setRenderPipelineState` for a preview program; `PreviewDrawTests` and `ShaderRenderer` both go through `FrameRenderer.encode`.
- **Recording never renders the viewer flag**, and always steps at `1 / frameRate` regardless of `timeMode`.
- **Never commit `MetalNodes.xcodeproj/project.pbxproj`.** After every `xcodebuild`: `git checkout -- MetalNodes.xcodeproj/project.pbxproj`. `xcodebuild` runs as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`.
- **Warning-free:** `swift build` prints zero `warning:` lines; `xcodebuild` for `platform=macOS` and `generic/platform=iOS` print zero.
- **GPU tests skip, not fail, without a device** (`MTLCreateSystemDefaultDevice() == nil`), using the `withKnownIssue("no Metal device")` pattern `PreviewDrawTests` uses.
- **Every fix has a mutation check** recorded in the report: revert the production change once, confirm the new test fails, restore.
- **Commit trailers:**
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```

## File Structure

| File | Responsibility |
|---|---|
| `MetalNodesKit/Sources/MetalNodesCore/Timeline.swift` | **New.** `Timeline` (document setting) and `TimelineClock` (pure playback state). |
| `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift` | `DocumentSettings.timeline` + Codable. |
| `MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift` | `lastExportSize` + Codable. |
| `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift` | `clock`, wall-clock bookkeeping; `timeOffset`/`resetRequested` removed. |
| `MetalNodesKit/Sources/MetalNodesRender/FrameRenderer.swift` | **New.** `FrameSpec`, `FrameRenderer.encode`. |
| `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift` | Clock advance + `FrameRenderer` call. |
| `MetalNodesKit/Sources/MetalNodesRender/Recording/FrameSink.swift` | **New.** `FrameBytes`, `FrameSink`, `ImageSequenceSink`. |
| `MetalNodesKit/Sources/MetalNodesRender/Recording/VideoSink.swift` | **New.** `AVAssetWriter` sink. |
| `MetalNodesKit/Sources/MetalNodesRender/Recording/ExportSession.swift` | **New.** Offscreen frame loop, readback, progress, cancel. |
| `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Recording.swift` | **New.** `requestRecording`, `record(...)`, clock sync helpers. |
| `MetalNodesKit/Sources/MetalNodesUI/Editor/RecordingDestination.swift` | **New.** `RecordingKind`, `RecordingDestination`, `MemoryRecordingDestination`. |
| `MetalNodesKit/Sources/MetalNodesUI/Editor/RecordingPanelMac.swift`, `RecordingDestinationPad.swift` | **New.** Platform placement. |
| `MetalNodesKit/Sources/MetalNodesUI/Editor/RecordingSheet.swift` | **New.** Size sheet + progress sheet. |
| `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift`, `EditorViewPad.swift`, `InspectorView.swift`, `EditorCommands.swift`, `PlatformServices.swift` | Preview controls, Timeline block, menu items, service injection. |
| Tests | `TimelineTests.swift` (Core), `PreviewStateTests`/`PreviewDrawTests`/`FrameSinkTests`/`ExportSessionTests`/`VideoSinkTests` (Render), `EditorRecordingTests`/`EditorViewStateTests` (UI). |

## Parallel waves (for the controller)

- **Wave A (parallel):** Task 1 (Core settings), Task 2 (Core clock), Task 6 (sinks; Render, new files only).
- **Wave B (serial on Render):** Task 3 (PreviewState/renderer/model sync — after 1, 2), Task 4 (FrameRenderer — after 3), Task 7 (ExportSession — after 4, 6), Task 8 (VideoSink — after 6; parallel with 7 if in its own worktree, both add files under `Recording/`).
- **Wave C:** Task 5 (preview UI + inspector + shortcuts — after 3), Task 9 (recording UI + services — after 7, 8).
- **Task 10** last, by the controller.

---

### Task 1: `Timeline` in the document

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Timeline.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift:116-172` (`DocumentSettings`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TimelineTests.swift` (new), `DocumentSettingsTests.swift`

**Interfaces:**
- Produces: `public struct Timeline: Sendable, Hashable, Codable { var duration: Double; var frameRate: Int; var loops: Bool; var frameCount: Int; static let frameRates = [24, 30, 60] }`, `DocumentSettings.timeline: Timeline`.

- [ ] **Step 1: Write the failing tests**

`MetalNodesKit/Tests/MetalNodesCoreTests/TimelineTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail to compile**

Run: `cd MetalNodesKit && swift test --filter TimelineTests`
Expected: build error — `Timeline` does not exist.

- [ ] **Step 3: Add the type and the setting**

`MetalNodesKit/Sources/MetalNodesCore/Timeline.swift`:

```swift
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
```

In `ShaderDocument.swift`'s `DocumentSettings`: add after `liveParameters`:

```swift
    /// The loop this document plays and records (spec §26.2). Optional in the file: a document
    /// written before M10 opens with `Timeline()`.
    public var timeline = Timeline()
```

Add `timeline` to `Keys`; in `init(from:)` add `timeline = try c.decodeIfPresent(Timeline.self, forKey: .timeline) ?? Timeline()`; in `encode(to:)` add `try c.encode(timeline, forKey: .timeline)`.

- [ ] **Step 4: Run the tests, the corpus, and the mutation**

Run: `cd MetalNodesKit && swift test --filter "TimelineTests|DocumentSettingsTests|FormatCorpusTests|ShaderPackageTests"`
Expected: PASS; corpus goldens untouched (the fixtures' settings gain nothing on read, and the goldens are MSL). Mutation: make `frameCount` return `Int(duration * Double(frameRate))` (truncating, no floor of 1) — `frameCountRoundsAndNeverDropsBelowOne` FAILS; restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Timeline.swift MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift MetalNodesKit/Tests/MetalNodesCoreTests/TimelineTests.swift
git commit -m "feat(core): Timeline — duration, frame rate and loop as an optional document setting"
```

---

### Task 2: `TimelineClock`

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Timeline.swift` (append)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TimelineTests.swift` (append)

**Interfaces:**
- Consumes: `Timeline`, `TimeMode` (Task 1 / existing).
- Produces: `public struct TimelineClock: Sendable, Equatable { var timeline: Timeline; var mode: TimeMode; var frame: Int; var isPlaying: Bool; var time: Float; var elapsedSeconds: Double; mutating func step(); mutating func seek(elapsed: Double); mutating func scrub(to frame: Int); mutating func reset(); mutating func retarget(_ timeline: Timeline, mode: TimeMode) }`.

- [ ] **Step 1: Write the failing tests**

Append to `TimelineTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail to compile**

Run: `cd MetalNodesKit && swift test --filter TimelineClockTests`
Expected: build error — `TimelineClock` does not exist.

- [ ] **Step 3: Implement the clock**

Append to `Timeline.swift`:

```swift
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
```

- [ ] **Step 4: Run, then mutations**

Run: `cd MetalNodesKit && swift test --filter "TimelineClockTests|TimelineTests"`
Expected: PASS. Mutations: (a) `step()` wrap → `frame = 1`: `steppingWrapsWhenLooping` FAILS; (b) `scrub` without `isPlaying = false`: `scrubbingClampsAndPauses` FAILS; restore both.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Timeline.swift MetalNodesKit/Tests/MetalNodesCoreTests/TimelineTests.swift
git commit -m "feat(core): TimelineClock — fixed-rate stepping, wall-clock seek, scrub, reset"
```

---

### Task 3: The renderer reads the clock; the model keeps it in step

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift:26-30`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift:16-17, 41-53`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift:146-147`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift:138-139, 191-192, 463-475`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Recording.swift` (clock sync only in this task)
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/PreviewStateTests.swift`, `MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift` (new)

**Interfaces:**
- Consumes: `TimelineClock` (Task 2).
- Produces: `PreviewState.clock: TimelineClock`, `PreviewState.playStartedAt: Double?`, `PreviewState.pausedElapsed: Double`; `EditorModel.syncClock()` (internal), `EditorModel.resetPlayback()`, `EditorModel.togglePlayback()`. `PreviewState.isPlaying`, `timeOffset`, `resetRequested` are **removed** — `isPlaying` lives on the clock.

- [ ] **Step 1: Write the failing tests**

Append to `PreviewStateTests.swift`:

```swift
    @Test func theClockStartsAtTheDefaultTimelineInWallClockMode() {
        let s = PreviewState()
        #expect(s.clock.timeline == Timeline())
        #expect(s.clock.mode == .wallClock)
        #expect(s.clock.frame == 0)
        #expect(s.clock.isPlaying)
    }
```

`MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift`:

```swift
import Testing
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@Suite struct EditorClockSyncTests {
    private func model() -> EditorModel {
        EditorModel(document: .sample(), compiler: RecordingCompiler())   // defined in EditorModelTests.swift
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
```

`RecordingCompiler` is the `ShaderCompiling` double at the top of `EditorModelTests.swift` (same test target); `EditorModel(document:compiler:)` is the existing initialiser with its other parameters defaulted.

- [ ] **Step 2: Run to verify they fail**

Run: `cd MetalNodesKit && swift test --filter "PreviewStateTests|EditorClockSyncTests"`
Expected: build errors — `clock`, `resetPlayback`, `togglePlayback` do not exist.

- [ ] **Step 3: `PreviewState` carries the clock**

Replace lines 26-30 of `PreviewState.swift` (`isPlaying`, `timeOffset`, `resetRequested` and their comments) with:

```swift
    /// Where playback is (spec §26.3). Seeded from the document's timeline and mode by the editor;
    /// stepped or seeked by the renderer every frame; scrubbed by the preview controls.
    public var clock = TimelineClock(timeline: Timeline(), mode: .wallClock)
    /// Wall-clock bookkeeping for `.wallClock` mode: when the current run of play began (in
    /// `CACurrentMediaTime()` seconds), and how much play had elapsed when it was last paused.
    /// Nil while paused.
    public var playStartedAt: Double?
    public var pausedElapsed: Double = 0
```

- [ ] **Step 4: The renderer advances the clock**

In `ShaderRenderer.swift` delete `private let startTime = CACurrentMediaTime()` and `private var pausedAt: Float?`. Replace the time block (lines 41-53, from the `// Time:` comment through `t = pausedAt!` and its closing brace) with:

```swift
        // Time comes from the clock (spec §26.3). Wall clock: elapsed play time places it —
        // pausing freezes `pausedElapsed`, resuming starts a new run from there, so there is no
        // jump. Fixed rate: exactly one frame per draw while playing, so the same draws always
        // produce the same `time` values — what makes recording frame-exact.
        switch state.clock.mode {
        case .wallClock:
            if state.clock.isPlaying {
                let now = CACurrentMediaTime()
                let started = state.playStartedAt ?? now
                state.playStartedAt = started
                state.clock.seek(elapsed: state.pausedElapsed + (now - started))
            } else if let started = state.playStartedAt {
                state.pausedElapsed += CACurrentMediaTime() - started
                state.playStartedAt = nil
            }
        case .fixedRate:
            state.playStartedAt = nil
            state.clock.step()
        }
        let t = state.clock.time
```

Everything after (`image.setReserved(time: t, …`) stays. A reset (`clock.reset()`) is done by the model (Step 5) and must also clear `pausedElapsed`/`playStartedAt`; scrubbing sets `isPlaying = false` on the clock, which the wall-clock branch above sees as a pause.

- [ ] **Step 5: The model seeds, syncs and drives the clock**

`MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Recording.swift`:

```swift
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
```

In `EditorModel.swift`: after `self.preview.orbit = viewState.orbit` in `init` (line 139) add `self.syncClock()`; after `preview.orbit = viewState.orbit` in `reload(package:)` (line 192) add `syncClock()` and `resetPlayback()`; in `perform`'s `.setSettings(let s)` case, after `document.settings = s` is assigned (find the assignment inside that case), add `syncClock()`. In `EditorView.swift:146-147` replace the two buttons' actions: `Button(model.preview.clock.isPlaying ? "Pause" : "Play") { model.togglePlayback() }` and `Button("Reset") { model.resetPlayback() }`. `grep -rn "resetRequested\|timeOffset\|preview.isPlaying" MetalNodesKit/Sources MetalNodesKit/Tests` must print nothing afterwards.

- [ ] **Step 6: Run the three targets and the mutation**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter "PreviewStateTests|EditorClockSyncTests|EditorModelTests|PreviewDrawTests"`
Expected: no warnings; PASS. Mutation: remove the `syncClock()` call from the `.setSettings` case — `changingTheTimelineRetargetsTheClock` FAILS; restore.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources MetalNodesKit/Tests
git commit -m "feat(preview): the renderer reads time from TimelineClock; fixed rate steps one frame per draw"
```

---

### Task 4: `FrameRenderer` — one encode path

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/FrameRenderer.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift` (the encode half of `draw(in:)`)
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/PreviewDrawTests.swift:88-126`

**Interfaces:**
- Produces: `public struct FrameSpec: Sendable { var time: Float; var size: CGSize; var mouse: SIMD2<Float>; var orbit: OrbitCamera; var mesh: PreviewMesh; var viewerRange: ClosedRange<Float> }` and `public enum FrameRenderer { @discardableResult public static func encode(program: PreviewProgram, uniforms image: UniformImage, spec: FrameSpec, into pass: MTLRenderPassDescriptor, uniformBuffer: MTLBuffer, meshes: MeshResources, command: MTLCommandBuffer) -> Bool }` (false when a RealityKit program has no mesh buffers).

- [ ] **Step 1: Rewrite the offscreen draw test to call the new API (it fails to compile until Step 2)**

In `PreviewDrawTests.encodesADrawForEveryPipelineKind`, replace everything from `var image = UniformImage(layout: shader.layout)` through `enc.endEncoding()` with:

```swift
            let image = UniformImage(layout: shader.layout)
            let uniforms = device.makeBuffer(length: max(image.bytes.count, 16), options: .storageModeShared)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1.0
            pass.depthAttachment.storeAction = .dontCare

            let cmd = queue.makeCommandBuffer()!
            let spec = FrameSpec(time: 0, size: CGSize(width: 64, height: 64), mouse: .zero,
                                 orbit: .default, mesh: .sphere, viewerRange: 0...1)
            // The same function `ShaderRenderer.draw(in:)` calls — one encode path (spec §26.4).
            let encoded = FrameRenderer.encode(program: PreviewProgram(pipeline: pipeline, textures: [:]),
                                               uniforms: image, spec: spec, into: pass,
                                               uniformBuffer: uniforms, meshes: meshes, command: cmd)
            #expect(encoded, "\(name): encode refused")
            if shader.target != .realityKit {
                #expect(pipeline.depthStencilState == nil, "\(name): a 2D program must not depth-test")
            }
```

Keep the `withCheckedContinuation` commit and the two `#expect`s on `cmd.error`/`cmd.status` after it.

- [ ] **Step 2: Extract the encoder**

`MetalNodesKit/Sources/MetalNodesRender/FrameRenderer.swift`:

```swift
import Foundation
import CoreGraphics
import Metal
import MetalNodesCore

/// Everything one frame needs beyond the program: the reserved uniforms and the 3D view.
public struct FrameSpec: Sendable {
    public var time: Float
    /// Drawable pixels — what the `resolution` uniform and the camera's aspect read.
    public var size: CGSize
    public var mouse: SIMD2<Float>
    public var orbit: OrbitCamera
    public var mesh: PreviewMesh
    public var viewerRange: ClosedRange<Float>

    public init(time: Float, size: CGSize, mouse: SIMD2<Float>, orbit: OrbitCamera,
                mesh: PreviewMesh, viewerRange: ClosedRange<Float>) {
        self.time = time; self.size = size; self.mouse = mouse
        self.orbit = orbit; self.mesh = mesh; self.viewerRange = viewerRange
    }
}

/// Encodes one frame of a preview program into any colour+depth pass (spec §26.4). Owns nothing:
/// the caller supplies the command buffer, the uniform buffer to fill and the mesh cache. The
/// live `MTKView` (`ShaderRenderer`) and the offscreen recorder (`ExportSession`) are its two
/// front ends, so they cannot draw differently.
public enum FrameRenderer {
    /// False when a RealityKit program's mesh buffers are unavailable; nothing was encoded then.
    @discardableResult
    public static func encode(program: PreviewProgram, uniforms image: UniformImage, spec: FrameSpec,
                              into pass: MTLRenderPassDescriptor, uniformBuffer: MTLBuffer,
                              meshes: MeshResources, command: MTLCommandBuffer) -> Bool {
        var image = image
        image.setReserved(time: spec.time,
                          resolution: SIMD2(Float(spec.size.width), Float(spec.size.height)),
                          mouse: spec.mouse)
        image.setViewerRange(spec.viewerRange)
        image.bytes.withUnsafeBytes { uniformBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(program.pipeline.state)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        for (index, texture) in program.textures {
            enc.setFragmentTexture(texture, index: index)
        }

        if program.pipeline.shader.target == .realityKit {
            guard let mesh = meshes.buffers(for: spec.mesh) else {
                enc.endEncoding()
                return false
            }
            var camera = spec.orbit.uniforms(aspect: Float(spec.size.width / max(spec.size.height, 1)))
            if let depth = program.pipeline.depthStencilState { enc.setDepthStencilState(depth) }
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 2)
            enc.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            for (index, texture) in program.textures { enc.setVertexTexture(texture, index: index) }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint16, indexBuffer: mesh.indices, indexBufferOffset: 0)
        } else {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        return true
    }
}
```

In `ShaderRenderer.draw(in:)`, replace everything from `image.setReserved(time: t, …` through `enc.endEncoding()` with:

```swift
        let spec = FrameSpec(time: t,
                             size: view.drawableSize, mouse: state.mouse,
                             orbit: state.orbit, mesh: state.mesh, viewerRange: state.viewerRange)
        inflight.wait()
        let buffer = ring!.next()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        guard FrameRenderer.encode(program: program, uniforms: image, spec: spec, into: pass,
                                   uniformBuffer: buffer, meshes: meshes, command: cmd) else {
            inflight.signal(); return
        }
```

followed by the existing `let sem = inflight … cmd.commit()`. The `guard … var image` at the top of `draw(in:)` becomes `let image` (nothing mutates it there now). `meshes` stays `lazy var` on the renderer. Confirm with `grep -rn "setRenderPipelineState" MetalNodesKit/Sources` that only `FrameRenderer.swift` remains.

- [ ] **Step 3: Run the Render suite, twice**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter MetalNodesRenderTests; MTL_DEBUG_LAYER=1 swift test --filter PreviewDrawTests 2>&1 | grep -E "Validation|Test run with"`
Expected: no warnings; PASS both ways, with `Metal API Validation Enabled` printed on the second. Mutation: in `FrameRenderer.encode` skip `setDepthStencilState` for RealityKit programs — the validation run still passes (depth state is optional) — so instead mutate `enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)` away: under `MTL_DEBUG_LAYER=1` the RealityKit draw fails validation (missing buffer binding) and the test records the command-buffer error; restore.

- [ ] **Step 4: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesRender MetalNodesKit/Tests/MetalNodesRenderTests/PreviewDrawTests.swift
git commit -m "refactor(render): FrameRenderer.encode is the one encode path behind the live view"
```

---

### Task 5: Preview controls, the Timeline block, playback shortcuts

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift:145-152` (control row)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift:228-232` (the Time picker becomes the Timeline block)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift` (a Playback command group)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift` (append), build on both platforms

**Interfaces:**
- Consumes: `EditorModel.togglePlayback/resetPlayback/scrub(to:)/stepPlayback(by:)` (Task 3), `Timeline.frameRates`.
- Produces: `EditorModel.setTimeline(_:)` (one `setSettings`, refuses `duration <= 0` with a notice).

- [ ] **Step 1: Write the failing model test**

Append to `EditorRecordingTests.swift`:

```swift
@Suite struct TimelineEditingTests {
    private func model() -> EditorModel { EditorModel(document: .sample(), compiler: RecordingCompiler()) }

    @Test func settingTheTimelineIsOneUndoableSettingsChange() {
        let m = model()
        m.setTimeline(Timeline(duration: 2, frameRate: 30, loops: false))
        #expect(m.document.settings.timeline == Timeline(duration: 2, frameRate: 30, loops: false))
        #expect(m.canUndo)
        m.undo()
        #expect(m.document.settings.timeline == Timeline())
    }

    @Test func aNonPositiveDurationIsRefusedWithANotice() {
        let m = model()
        m.setTimeline(Timeline(duration: 0, frameRate: 30, loops: true))
        #expect(m.document.settings.timeline == Timeline())
        #expect(m.notice != nil)
    }
}
```

Run: `cd MetalNodesKit && swift test --filter TimelineEditingTests` — Expected: build error, `setTimeline` missing.

- [ ] **Step 2: The model API**

Append to `EditorModel+Recording.swift`'s extension:

```swift
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
```

- [ ] **Step 3: The preview control row**

In `EditorView.swift`, replace the `HStack { Button(... "Pause" : "Play") … Text("gen …") }` block with:

```swift
            HStack(spacing: 8) {
                Button(model.preview.clock.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
                Button("Reset") { model.resetPlayback() }
                // The scrubber (spec §26.3): dragging pauses and moves; releasing does not resume.
                Slider(value: Binding(get: { Double(model.preview.clock.frame) },
                                      set: { model.scrub(to: Int($0.rounded())) }),
                       in: 0...Double(max(model.preview.clock.timeline.frameCount - 1, 0)), step: 1)
                    .controlSize(.mini)
                Text("\(model.preview.clock.frame + 1) / \(model.preview.clock.timeline.frameCount)")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 64, alignment: .trailing)
                Text(String(format: "%.2f s", model.preview.clock.mode == .wallClock && !model.preview.clock.timeline.loops
                            ? model.preview.clock.elapsedSeconds : Double(model.preview.clock.time)))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 56, alignment: .trailing)
                Toggle("Loop", isOn: Binding(get: { model.document.settings.timeline.loops },
                                             set: { on in var t = model.document.settings.timeline; t.loops = on; model.setTimeline(t) }))
                    .toggleStyle(.switch).controlSize(.mini)
                Text("gen \(model.preview.pipeline?.generation ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DraculaToken.muted.color)
            }
            .controlSize(.small)
```

- [ ] **Step 4: The Timeline block in the inspector**

In `InspectorView.swift`, replace the `Picker("Time", …)` and its `.pickerStyle(.segmented)` with:

```swift
            Text("Timeline").font(.headline)
            Picker("Time", selection: Binding(get: { s.timeMode }, set: { m in var n = s; n.timeMode = m; model.apply(.setSettings(n)) })) {
                Text("Wall clock").tag(TimeMode.wallClock)
                Text("Fixed rate").tag(TimeMode.fixedRate)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Duration").font(.caption)
                TextField("s", value: Binding(get: { s.timeline.duration },
                                              set: { d in var t = s.timeline; t.duration = d; model.setTimeline(t) }),
                          format: .number.precision(.fractionLength(1)))
                    .frame(width: 60)
                Text("s").font(.caption)
                Picker("Frame rate", selection: Binding(get: { s.timeline.frameRate },
                                                        set: { r in var t = s.timeline; t.frameRate = r; model.setTimeline(t) })) {
                    ForEach(Timeline.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Loop", isOn: Binding(get: { s.timeline.loops },
                                             set: { on in var t = s.timeline; t.loops = on; model.setTimeline(t) }))
                    .toggleStyle(.switch)
            }
            Text("\(s.timeline.frameCount) frames per loop. Fixed rate steps one frame per drawn frame; recording always does.")
                .font(.caption2).foregroundStyle(DraculaToken.muted.color)
```

`s` is the settings binding variable already in scope there (the `Picker("Time"` line uses it).

- [ ] **Step 5: Playback shortcuts**

In `EditorCommands.swift`, inside the `CommandGroup(after: .sidebar)` block, after the existing zoom items, add:

```swift
            Divider()
            // Playback (spec §26.3): bare keys, gated on the canvas like every other bare key.
            Button(model?.preview.clock.isPlaying == true ? "Pause" : "Play") { model?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!canvasFocused)
            Button("Previous Frame") { model?.stepPlayback(by: -1) }
                .keyboardShortcut(",", modifiers: [])
                .disabled(!canvasFocused)
            Button("Next Frame") { model?.stepPlayback(by: 1) }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!canvasFocused)
            Button("Reset Playback") { model?.resetPlayback() }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(!canvasFocused)
```

Check first that `.space`, `,` and `.` are not already bound anywhere in the file (`grep -n 'keyboardShortcut' EditorCommands.swift`); if a clash exists, report it rather than changing the existing binding.

- [ ] **Step 6: Build both platforms and run the UI suite**

Run (repo root):
```bash
cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter "TimelineEditingTests|EditorClockSyncTests|EditorModelTests|EditorUndoTests"; cd ..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS' build -quiet 2>&1 | grep -E "warning:|error:"
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```
Expected: nothing from the greps; PASS. Mutation: drop the `guard timeline.duration > 0` — `aNonPositiveDurationIsRefusedWithANotice` FAILS; restore.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesUI MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift
git commit -m "feat(preview): scrubber, frame counter and loop toggle; Timeline block; playback shortcuts"
```

---

### Task 6: `FrameSink` and `ImageSequenceSink`

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/Recording/FrameSink.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/FrameSinkTests.swift` (new)

**Interfaces:**
- Produces: `public struct FrameBytes: Sendable { let width: Int; let height: Int; let bytesPerRow: Int; let bgra: [UInt8] }`, `public protocol FrameSink: Sendable { func begin(width: Int, height: Int, frameRate: Int) async throws; func write(_ frame: FrameBytes, index: Int) async throws; func finish() async throws; func abandon() async }`, `public final class ImageSequenceSink: FrameSink` with `init(directory: URL, baseName: String, singleFileName: String? = nil)` and `static func cgImage(from frame: FrameBytes) -> CGImage?`.

- [ ] **Step 1: Write the failing test**

`MetalNodesKit/Tests/MetalNodesRenderTests/FrameSinkTests.swift`:

```swift
import Foundation
import ImageIO
import Testing
@testable import MetalNodesRender

@Suite struct FrameSinkTests {
    /// A 2×2 BGRA frame: red, green / blue, half-alpha white.
    private func frame() -> FrameBytes {
        let px: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255], [255, 255, 255, 128]]
        return FrameBytes(width: 2, height: 2, bytesPerRow: 8, bgra: px.flatMap { $0 })
    }

    private func pixels(of url: URL) throws -> [[UInt8]] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var out = [UInt8](repeating: 0, count: 16)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: &out, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        return stride(from: 0, to: 16, by: 4).map { Array(out[$0..<$0 + 4]) }   // RGBA, premultiplied
    }

    @Test func aSequenceWritesNumberedPNGsWithAlpha() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-seq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "clip")
        try await sink.begin(width: 2, height: 2, frameRate: 30)
        try await sink.write(frame(), index: 0)
        try await sink.write(frame(), index: 1)
        try await sink.finish()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["clip_0001.png", "clip_0002.png"])
        let px = try pixels(of: dir.appendingPathComponent("clip_0001.png"))
        #expect(px[0] == [255, 0, 0, 255])          // BGRA red came out red
        #expect(px[1] == [0, 255, 0, 255])
        #expect(px[2] == [0, 0, 255, 255])
        #expect(px[3][3] == 128)                    // alpha survived
    }

    @Test func aSnapshotWritesOneNamedFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "x", singleFileName: "shot.png")
        try await sink.begin(width: 2, height: 2, frameRate: 30)
        try await sink.write(frame(), index: 0)
        try await sink.finish()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("shot.png").path))
    }

    @Test func abandonRemovesWhatWasWritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-abandon-\(UUID().uuidString)")
        let sink = ImageSequenceSink(directory: dir, baseName: "clip")
        try await sink.begin(width: 2, height: 2, frameRate: 30)
        try await sink.write(frame(), index: 0)
        await sink.abandon()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `cd MetalNodesKit && swift test --filter FrameSinkTests` — Expected: build error.

- [ ] **Step 3: Implement**

`MetalNodesKit/Sources/MetalNodesRender/Recording/FrameSink.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One rendered frame, read back from the GPU: tightly packed or padded BGRA8, top row first.
public struct FrameBytes: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bgra: [UInt8]
    public init(width: Int, height: Int, bytesPerRow: Int, bgra: [UInt8]) {
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.bgra = bgra
    }
}

/// Where `ExportSession` sends frames (spec §26.5). `begin` before the first `write`; `finish`
/// after the last; `abandon` on cancel or failure removes whatever was written.
public protocol FrameSink: Sendable {
    func begin(width: Int, height: Int, frameRate: Int) async throws
    func write(_ frame: FrameBytes, index: Int) async throws
    func finish() async throws
    func abandon() async
}

/// PNG per frame — `<baseName>_0001.png …` — or, with `singleFileName`, one file (the snapshot).
public final class ImageSequenceSink: FrameSink, @unchecked Sendable {
    private let directory: URL
    private let baseName: String
    private let singleFileName: String?
    private let lock = NSLock()
    private var written: [URL] = []

    public init(directory: URL, baseName: String, singleFileName: String? = nil) {
        self.directory = directory
        self.baseName = baseName
        self.singleFileName = singleFileName
    }

    public func begin(width: Int, height: Int, frameRate: Int) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ frame: FrameBytes, index: Int) async throws {
        guard let image = Self.cgImage(from: frame) else { throw RecordingError.frameConversionFailed(index) }
        let name = singleFileName ?? String(format: "%@_%04d.png", baseName, index + 1)
        let url = directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RecordingError.frameWriteFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RecordingError.frameWriteFailed(url) }
        lock.withLock { written.append(url) }
    }

    public func finish() async throws {}

    public func abandon() async {
        try? FileManager.default.removeItem(at: directory)
    }

    /// BGRA8, top row first, straight alpha — what the readback holds — as a `CGImage`.
    public static func cgImage(from frame: FrameBytes) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: Data(frame.bgra) as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

public enum RecordingError: Error, LocalizedError, Sendable, Equatable {
    case frameConversionFailed(Int)
    case frameWriteFailed(URL)
    case writerFailed(String)
    case cancelled
    case noDevice

    public var errorDescription: String? {
        switch self {
        case .frameConversionFailed(let i): "Frame \(i + 1) could not be converted to an image"
        case .frameWriteFailed(let url): "Could not write \(url.lastPathComponent)"
        case .writerFailed(let why): "The video writer failed: \(why)"
        case .cancelled: "Recording cancelled"
        case .noDevice: "No Metal device is available"
        }
    }
}
```

`byteOrder32Little` + `alphaLast` over BGRA memory is how Core Graphics reads BGRA8 with the alpha in the high byte, so red in memory (`0,0,255,255` as B,G,R,A) decodes as red. If the first test's colour assertions come out swapped, the `bitmapInfo` is the thing to fix, not the test.

- [ ] **Step 4: Run and mutate**

Run: `cd MetalNodesKit && swift test --filter FrameSinkTests`
Expected: PASS. Mutation: use `CGImageAlphaInfo.noneSkipLast` in `cgImage(from:)` — the alpha assertion FAILS; restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesRender/Recording/FrameSink.swift MetalNodesKit/Tests/MetalNodesRenderTests/FrameSinkTests.swift
git commit -m "feat(render): FrameSink protocol and ImageSequenceSink (PNG sequence or snapshot)"
```

---

### Task 7: `ExportSession` — offscreen, frame-exact

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/Recording/ExportSession.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/ExportSessionTests.swift` (new)

**Interfaces:**
- Consumes: `FrameRenderer.encode`, `FrameSpec` (Task 4), `FrameSink`, `ImageSequenceSink`, `RecordingError` (Task 6), `Timeline` (Task 1), `ShaderCompiler`/`CompiledPipeline`, `MeshResources`.
- Produces: `public struct RecordingProgress: Sendable, Equatable { let frame: Int; let frameCount: Int }`, `public actor ExportSession { init(device: MTLDevice, program: PreviewProgram, uniforms: UniformImage, spec: FrameSpec, timeline: Timeline, sink: any FrameSink) throws; func run(progress: @Sendable (RecordingProgress) -> Void) async throws }` — throws `RecordingError.cancelled` when the task is cancelled, after `sink.abandon()`. A `Timeline` with `frameCount == 1` and `spec.time` preset renders a snapshot: `run` uses `spec.time` for frame 0 when `timeline.frameCount == 1` and `spec.time != 0`; otherwise `time = k / frameRate`.

`PreviewProgram` holds `MTLTexture`s and is not `Sendable`; the session takes it in its initialiser (isolated) and never lets it out. Mark the initialiser's parameter `PreviewProgram` as it is — actors accept non-Sendable values at `init` when called from the same isolation domain (`@MainActor` here); the tests and the model both create the session on the main actor.

- [ ] **Step 1: Write the failing test**

`MetalNodesKit/Tests/MetalNodesRenderTests/ExportSessionTests.swift`:

```swift
import Foundation
import ImageIO
import Metal
import Testing
import MetalNodesCore
@testable import MetalNodesRender

@Suite struct ExportSessionTests {
    /// A fragment document whose colour is `float4(time, 0, 0, 1)`: an Expression fed by Time.
    static func timeDocument() -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        let expr = NodeInstance(id: NodeID(), kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("float4(t, 0.0, 0.0, 1.0)"), "type": .enumCase("color")])
        for n in [terminal, time, expr] { g.nodes[n.id] = n }
        g.inputs[SocketRef(expr.id, "t")] = SocketRef(time.id, "time")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        return doc
    }

    static func redChannel(of url: URL) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return out[0]
    }

    @MainActor
    @Test func framesAreExactlyKOverFrameRate() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let shader = try ShaderGenerator.generate(Self.timeDocument())
        let compiler = try ShaderCompiler(device: device)
        guard case .success(let pipeline) = await compiler.compile(shader, generation: 1) else {
            Issue.record("compile failed"); return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ImageSequenceSink(directory: dir, baseName: "t")
        let spec = FrameSpec(time: 0, size: CGSize(width: 8, height: 8), mouse: SIMD2(4, 4),
                             orbit: .default, mesh: .sphere, viewerRange: 0...1)
        // 3 frames at 60 fps: t = 0, 1/60, 2/60 → red 0, 4.25, 8.5 in 8-bit sRGB-encoded terms is
        // not linear; the pipeline writes to a `.bgra8Unorm` target, so the stored byte is
        // round(t * 255) with no colour management: 0, 4, 9 (±1).
        let session = try ExportSession(device: device, program: PreviewProgram(pipeline: pipeline, textures: [:]),
                                        uniforms: UniformImage(layout: shader.layout), spec: spec,
                                        timeline: Timeline(duration: 0.05, frameRate: 60, loops: true), sink: sink)
        var seen: [RecordingProgress] = []
        try await session.run { seen.append($0) }
        #expect(seen.map(\.frame) == [1, 2, 3])
        #expect(seen.allSatisfy { $0.frameCount == 3 })
        for k in 0..<3 {
            let red = try Self.redChannel(of: dir.appendingPathComponent(String(format: "t_%04d.png", k + 1)))
            let expected = Int((Double(k) / 60.0 * 255).rounded())
            #expect(abs(Int(red) - expected) <= 1, "frame \(k): red \(red), expected \(expected)")
        }
    }

    @MainActor
    @Test func cancellationAbandonsTheOutput() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let shader = try ShaderGenerator.generate(Self.timeDocument())
        let compiler = try ShaderCompiler(device: device)
        guard case .success(let pipeline) = await compiler.compile(shader, generation: 1) else {
            Issue.record("compile failed"); return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-cancel-\(UUID().uuidString)")
        let sink = ImageSequenceSink(directory: dir, baseName: "t")
        let spec = FrameSpec(time: 0, size: CGSize(width: 8, height: 8), mouse: .zero,
                             orbit: .default, mesh: .sphere, viewerRange: 0...1)
        let session = try ExportSession(device: device, program: PreviewProgram(pipeline: pipeline, textures: [:]),
                                        uniforms: UniformImage(layout: shader.layout), spec: spec,
                                        timeline: Timeline(duration: 10, frameRate: 60, loops: true), sink: sink)
        let task = Task {
            try await session.run { p in if p.frame == 3 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        await #expect(throws: RecordingError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
```

`Issue.record("skipped")` inside `withKnownIssue` is the pattern `PreviewDrawTests` uses to skip without a device. If `progress` must be `@Sendable` and the closure captures `seen` (a local var), collect through an actor-isolated array instead: declare `let box = ProgressBox()` (`@MainActor final class ProgressBox { var seen: [RecordingProgress] = [] }`) and append inside `Task { @MainActor in box.seen.append(p) }`; then `await` a yield before asserting. Choose whichever compiles under strict concurrency and keep the assertions.

- [ ] **Step 2: Run to verify it fails to compile**

Run: `cd MetalNodesKit && swift test --filter ExportSessionTests` — Expected: build error.

- [ ] **Step 3: Implement the session**

`MetalNodesKit/Sources/MetalNodesRender/Recording/ExportSession.swift`:

```swift
import Foundation
import CoreGraphics
import Metal
import MetalNodesCore

public struct RecordingProgress: Sendable, Equatable {
    /// Frames completed so far (1-based when reported), and the total.
    public let frame: Int
    public let frameCount: Int
    public init(frame: Int, frameCount: Int) { self.frame = frame; self.frameCount = frameCount }
}

/// Renders every frame of a timeline offscreen and hands the pixels to a sink (spec §26.5).
/// One frame in flight, `waitUntilCompleted` per frame: a 240-frame 1080p clip takes seconds,
/// and the simplicity is worth more than the throughput. Never touches the live view.
public actor ExportSession {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let program: PreviewProgram
    private let uniforms: UniformImage
    private var spec: FrameSpec
    private let timeline: Timeline
    private let sink: any FrameSink
    private let meshes: MeshResources
    private let color: MTLTexture
    private let depth: MTLTexture
    private let uniformBuffer: MTLBuffer
    private let readback: MTLBuffer
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    public init(device: MTLDevice, program: PreviewProgram, uniforms: UniformImage, spec: FrameSpec,
                timeline: Timeline, sink: any FrameSink) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RecordingError.noDevice }
        self.queue = queue
        self.program = program
        self.uniforms = uniforms
        self.spec = spec
        self.timeline = timeline
        self.sink = sink
        self.meshes = MeshResources(device: device)
        width = max(1, Int(spec.size.width.rounded()))
        height = max(1, Int(spec.size.height.rounded()))
        bytesPerRow = width * 4
        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let color = target(.bgra8Unorm), let depth = target(ShaderCompiler.depthPixelFormat),
              let uniformBuffer = device.makeBuffer(length: max(uniforms.bytes.count, 16), options: .storageModeShared),
              let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared)
        else { throw RecordingError.noDevice }
        self.color = color
        self.depth = depth
        self.uniformBuffer = uniformBuffer
        self.readback = readback
    }

    /// Renders and writes every frame. Throws `RecordingError.cancelled` (after abandoning the
    /// sink's output) when the surrounding task is cancelled; rethrows sink errors the same way.
    public func run(progress: @Sendable @escaping (RecordingProgress) -> Void) async throws {
        let count = timeline.frameCount
        try await sink.begin(width: width, height: height, frameRate: timeline.frameRate)
        do {
            for k in 0..<count {
                if Task.isCancelled { throw RecordingError.cancelled }
                // A one-frame timeline with a preset time is a snapshot at that time.
                spec.time = (count == 1 && spec.time != 0) ? spec.time : Float(k) / Float(timeline.frameRate)
                let bytes = try renderFrame()
                try await sink.write(FrameBytes(width: width, height: height, bytesPerRow: bytesPerRow, bgra: bytes), index: k)
                progress(RecordingProgress(frame: k + 1, frameCount: count))
            }
            try await sink.finish()
        } catch {
            await sink.abandon()
            throw error
        }
    }

    private func renderFrame() throws -> [UInt8] {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
        guard let cmd = queue.makeCommandBuffer() else { throw RecordingError.noDevice }
        guard FrameRenderer.encode(program: program, uniforms: uniforms, spec: spec, into: pass,
                                   uniformBuffer: uniformBuffer, meshes: meshes, command: cmd) else {
            throw RecordingError.writerFailed("the frame could not be encoded")
        }
        guard let blit = cmd.makeBlitCommandEncoder() else { throw RecordingError.noDevice }
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw RecordingError.writerFailed(error.localizedDescription) }
        return Array(UnsafeRawBufferPointer(start: readback.contents(), count: bytesPerRow * height))
    }
}
```

If `PreviewProgram` in an actor's stored property draws a strict-concurrency diagnostic, mark the stored property `nonisolated(unsafe)` with a comment: the session is the texture's only reader after `init`, and the live view holds its own reference. `cmd.waitUntilCompleted()` inside an actor is acceptable here (offline, one frame at a time, never on the main actor).

- [ ] **Step 4: Run, then mutation**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter "ExportSessionTests|FrameSinkTests|PreviewDrawTests"`
Expected: no warnings; PASS (skips without a device). Mutation: set `spec.time = 0` for every k — `framesAreExactlyKOverFrameRate` FAILS on frames 1 and 2; restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesRender/Recording/ExportSession.swift MetalNodesKit/Tests/MetalNodesRenderTests/ExportSessionTests.swift
git commit -m "feat(render): ExportSession renders a timeline offscreen, frame-exact, into any FrameSink"
```

---

### Task 8: `VideoSink` on `AVAssetWriter`

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/Recording/VideoSink.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/VideoSinkTests.swift` (new)

**Interfaces:**
- Consumes: `FrameSink`, `FrameBytes`, `RecordingError` (Task 6).
- Produces: `public final class VideoSink: FrameSink` with `init(url: URL)`; `static func evenSize(_ size: CGSize) -> CGSize` (rounds each dimension up to even).

- [ ] **Step 1: Write the failing test**

`MetalNodesKit/Tests/MetalNodesRenderTests/VideoSinkTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import MetalNodesRender

@Suite struct VideoSinkTests {
    private func frame(_ k: Int, width: Int, height: Int) -> FrameBytes {
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        for p in stride(from: 0, to: bgra.count, by: 4) { bgra[p + 2] = UInt8(min(255, k * 20)); bgra[p + 3] = 255 }
        return FrameBytes(width: width, height: height, bytesPerRow: width * 4, bgra: bgra)
    }

    @Test func twelveFramesAtSixtyMakeAFifthOfASecondOfH264() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 60)
        for k in 0..<12 { try await sink.write(frame(k, width: 64, height: 64), index: k) }
        try await sink.finish()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 0.2) < 1.0 / 60.0)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.nominalFrameRate)
        #expect(abs(Double(rate) - 60) < 0.5)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 64))
    }

    @Test func oddSizesAreRoundedUpToEven() {
        #expect(VideoSink.evenSize(CGSize(width: 63, height: 65)) == CGSize(width: 64, height: 66))
        #expect(VideoSink.evenSize(CGSize(width: 64, height: 64)) == CGSize(width: 64, height: 64))
    }

    @Test func abandonRemovesThePartialFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString).mp4")
        let sink = VideoSink(url: url)
        try await sink.begin(width: 64, height: 64, frameRate: 30)
        try await sink.write(frame(0, width: 64, height: 64), index: 0)
        await sink.abandon()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `cd MetalNodesKit && swift test --filter VideoSinkTests` — Expected: build error.

- [ ] **Step 3: Implement**

`MetalNodesKit/Sources/MetalNodesRender/Recording/VideoSink.swift`:

```swift
import AVFoundation
import CoreVideo
import Foundation

/// H.264 in an `.mp4`, one frame per timeline frame at `k / frameRate` (spec §26.5).
/// `AVAssetWriter` is not `Sendable`; the class serialises every call through `queue`, so it can
/// be handed to the session's actor and driven from there.
public final class VideoSink: FrameSink, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "MetalNodes.VideoSink")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameRate = 60

    public init(url: URL) { self.url = url }

    /// H.264 refuses odd dimensions; round each up to the next even number.
    public static func evenSize(_ size: CGSize) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat { let i = Int(v.rounded()); return CGFloat(i % 2 == 0 ? i : i + 1) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    public func begin(width: Int, height: Int, frameRate: Int) async throws {
        try queue.sync {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            guard writer.canAdd(input) else { throw RecordingError.writerFailed("cannot add a video input") }
            writer.add(input)
            guard writer.startWriting() else { throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; self.input = input; self.adaptor = adaptor; self.frameRate = frameRate
        }
    }

    public func write(_ frame: FrameBytes, index: Int) async throws {
        // `isReadyForMoreMediaData` is polled rather than awaited: offline writing at one frame
        // at a time is never far ahead of the encoder.
        while let input, !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        try queue.sync {
            guard let adaptor, let pool = adaptor.pixelBufferPool else { throw RecordingError.writerFailed("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw RecordingError.writerFailed("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let dstRow = CVPixelBufferGetBytesPerRow(buffer)
            guard let dst = CVPixelBufferGetBaseAddress(buffer) else { throw RecordingError.writerFailed("no base address") }
            frame.bgra.withUnsafeBytes { src in
                for y in 0..<frame.height {
                    memcpy(dst + y * dstRow, src.baseAddress! + y * frame.bytesPerRow, frame.width * 4)
                }
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw RecordingError.writerFailed(writer?.error?.localizedDescription ?? "append")
            }
        }
    }

    public func finish() async throws {
        guard let writer, let input else { return }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "finishWriting") }
    }

    public func abandon() async {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run and mutate**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter VideoSinkTests`
Expected: no warnings; PASS. Mutation: use `timescale: 30` regardless of `frameRate` — the duration/frame-rate assertions FAIL; restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesRender/Recording/VideoSink.swift MetalNodesKit/Tests/MetalNodesRenderTests/VideoSinkTests.swift
git commit -m "feat(render): VideoSink — H.264 mp4 through AVAssetWriter at the timeline's frame rate"
```

---

### Task 9: Recording in the app — service seam, model, sheet, menus

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/RecordingDestination.swift`, `RecordingPanelMac.swift`, `RecordingDestinationPad.swift`, `RecordingSheet.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Recording.swift` (append), `PlatformServices.swift:81-97`, `EditorCommands.swift` (File menu), `EditorView.swift` (presentation), `EditorViewPad.swift:139-152` (menu), `MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift` (`lastExportSize`)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift` (append), `EditorViewStateTests.swift`

**Interfaces:**
- Consumes: `ExportSession`, `VideoSink`, `ImageSequenceSink`, `RecordingProgress`, `RecordingError`, `FrameSpec` (Tasks 6–8), `EditorModel` playback API (Task 3).
- Produces: `public enum RecordingKind: Sendable, CaseIterable { case video, imageSequence, snapshot }`, `public protocol RecordingDestination: AnyObject { @MainActor func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome }`, `MemoryRecordingDestination`, `EditorServices.recordingDestination`, `EditorModel.recordingRequest: RecordingKind?`, `EditorModel.requestRecording(_:)`, `EditorModel.record(_ kind: RecordingKind, size: CGSize, device: MTLDevice, destination: any RecordingDestination, progress: @escaping @MainActor (RecordingProgress) -> Void) async -> ExportOutcome`, `EditorModel.recordingTask: Task<Void, Never>?`, `EditorViewState.lastExportSize: CGSize?`.

- [ ] **Step 1: Write the failing tests**

Append to `EditorRecordingTests.swift`:

```swift
/// The Render suite's time document, duplicated here because test targets cannot share sources.
enum ExportSessionFixture {
    static func timeDocument() -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        let expr = NodeInstance(id: NodeID(), kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("float4(t, 0.0, 0.0, 1.0)"), "type": .enumCase("color")])
        for n in [terminal, time, expr] { g.nodes[n.id] = n }
        g.inputs[SocketRef(expr.id, "t")] = SocketRef(time.id, "time")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        return doc
    }
}

@MainActor
@Suite struct RecordingTests {
    /// A model on a real compiler, compiled and idle, so `preview.program` is the document's program.
    private func compiledModel(_ device: MTLDevice) async throws -> EditorModel {
        let m = EditorModel(document: ExportSessionFixture.timeDocument(), compiler: try ShaderCompiler(device: device))
        m.debounceInterval = .milliseconds(5)
        await m.awaitIdle()
        #expect(m.preview.program != nil)
        return m
    }

    static func channels(of url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return out
    }

    @MainActor
    @Test func aSnapshotRendersOneFrameAndHandsTheFileToTheDestination() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let m = try await compiledModel(device)
        m.scrub(to: 120)                                              // t = 0.5 → red ≈ 128
        let destination = MemoryRecordingDestination()
        let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .saved)
        let placed = try #require(destination.placed.first)
        #expect(placed.kind == .snapshot)
        #expect(placed.url.pathExtension == "png")
        let px = try Self.channels(of: placed.url)
        #expect(abs(Int(px[0]) - 128) <= 1, "red \(px[0])")
        #expect(m.viewState.lastExportSize == CGSize(width: 8, height: 8))
    }

    /// The viewer flag is never recorded (spec §26.5): with the viewer on the Time socket the pane
    /// shows grey (time in every channel), but the recording is the document's red ramp.
    @MainActor
    @Test func theViewerFlagIsNotRecorded() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let m = try await compiledModel(device)
        let timeNode = try #require(m.document.root.nodes.values.first { $0.kind == .builtin("input.time") })
        m.setViewer(SocketRef(timeNode.id, "time"))
        await m.awaitIdle()
        m.scrub(to: 120)
        let destination = MemoryRecordingDestination()
        let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .saved)
        let px = try Self.channels(of: try #require(destination.placed.first?.url))
        #expect(abs(Int(px[0]) - 128) <= 1)
        #expect(px[1] == 0, "green \(px[1]): the viewer program was recorded")
    }

    @MainActor
    @Test func aVideoRecordsEveryFrameOfTheTimeline() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let m = try await compiledModel(device)
        m.setTimeline(Timeline(duration: 0.1, frameRate: 30, loops: true))     // 3 frames
        let destination = MemoryRecordingDestination()
        var last: RecordingProgress?
        let outcome = await m.record(.video, size: CGSize(width: 16, height: 16), device: device,
                                     destination: destination) { last = $0 }
        #expect(outcome == .saved)
        #expect(last == RecordingProgress(frame: 3, frameCount: 3))
        #expect(destination.placed.first?.url.pathExtension == "mp4")
    }

    @MainActor
    @Test func aDocumentThatDoesNotCompileIsRefusedBeforeAnyRenderer() async {
        let m = EditorModel(document: ShaderDocument(), compiler: RecordingCompiler())   // no terminal
        let destination = MemoryRecordingDestination()
        let outcome = await m.record(.video, size: CGSize(width: 8, height: 8), device: MTLCreateSystemDefaultDevice(),
                                     destination: destination) { _ in }
        #expect(outcome == .failed("The graph has errors; fix them before recording."))
        #expect(destination.placed.isEmpty)
    }
}
```

`RecordingCompiler` is the double at the top of `EditorModelTests.swift`; `setViewer(_:)` is the model's existing viewer API (check its exact name with `grep -n "func setViewer" Sources/MetalNodesUI/Editor/*.swift` and use that). `record`'s `device` parameter is `MTLDevice?` so the refusal test needs no device; nil after the graph check returns `.failed("No Metal device is available")`.

`EditorViewStateTests.swift`: add

```swift
    @Test func lastExportSizeIsOptionalAndRoundTrips() throws {
        var v = EditorViewState()
        #expect(v.lastExportSize == nil)
        v.lastExportSize = CGSize(width: 1920, height: 1080)
        let back = try JSONDecoder().decode(EditorViewState.self, from: JSONEncoder().encode(v))
        #expect(back.lastExportSize == CGSize(width: 1920, height: 1080))
    }
```

- [ ] **Step 2: Run to verify they fail to compile**

Run: `cd MetalNodesKit && swift test --filter "RecordingTests|EditorViewStateTests"` — Expected: build errors.

- [ ] **Step 3: The seam and the doubles**

`MetalNodesKit/Sources/MetalNodesUI/Editor/RecordingDestination.swift`:

```swift
import Foundation
import MetalNodesCore

/// What File ▸ Export Video… / Export Image Sequence… / Snapshot PNG… produce (spec §26.5).
public enum RecordingKind: Sendable, CaseIterable, Equatable {
    case video, imageSequence, snapshot

    public var title: String {
        switch self {
        case .video: "Export Video"
        case .imageSequence: "Export Image Sequence"
        case .snapshot: "Snapshot PNG"
        }
    }
    /// A video and a snapshot are one file; a sequence is a folder.
    public var isFolder: Bool { self == .imageSequence }
    public var fileExtension: String { self == .video ? "mp4" : "png" }
}

/// Moves a finished recording from its temporary location to where the user wants it: save/open
/// panels on the Mac, `fileExporter` on the iPad, a recorder in tests. The session renders to a
/// temporary URL first so rendering never needs a security-scoped grant (spec §26.5).
@MainActor
public protocol RecordingDestination: AnyObject {
    /// `temporary` is a file (video, snapshot) or a directory (sequence); the implementation moves
    /// or copies it and may ignore `suggestedName`.
    func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome
}

@MainActor
public final class MemoryRecordingDestination: RecordingDestination {
    public var outcome: ExportOutcome = .saved
    public private(set) var placed: [(url: URL, kind: RecordingKind, suggestedName: String)] = []
    public init() {}
    public func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome {
        placed.append((temporary, kind, suggestedName))
        return outcome
    }
}
```

In `PlatformServices.swift`, add `public var recordingDestination: any RecordingDestination` to `EditorServices`, a third initialiser parameter with a default of `MemoryRecordingDestination()` (so existing call sites compile), and in `.platform` pass `RecordingPanelMac()` / `RecordingDestinationPad()`.

`EditorViewState.swift`: add `public var lastExportSize: CGSize? = nil` with the doc comment `/// The last recording size the export sheet was confirmed with (spec §26.5).`, a `lastExportSize` key, `decodeIfPresent` on read and `encodeIfPresent` on write.

- [ ] **Step 4: The model**

Append to `EditorModel+Recording.swift`'s extension (add `import Metal` and `import CoreGraphics` at the top of the file):

```swift
    /// Bumped by the File menu; the view presents the size sheet on change.
    public func requestRecording(_ kind: RecordingKind) { recordingRequest = kind; recordingRequestCount += 1 }

    /// Renders the document's program at `size` and places the result (spec §26.5). Refuses a graph
    /// that does not generate before any renderer is built. Runs the session off the main actor;
    /// `progress` is delivered on it.
    public func record(_ kind: RecordingKind, size: CGSize, device: MTLDevice?,
                       destination: any RecordingDestination,
                       progress: @escaping @MainActor (RecordingProgress) -> Void) async -> ExportOutcome {
        guard (try? exportFiles()) != nil, preview.program != nil else {
            return .failed("The graph has errors; fix them before recording.")
        }
        guard let device else { return .failed(RecordingError.noDevice.errorDescription ?? "No Metal device") }
        // The viewer flag is never recorded (spec §26.5). With no viewer the live program *is* the
        // document's; with one set, compile the document's program once for this recording.
        let program: PreviewProgram
        let uniforms: UniformImage
        if viewState.viewer == nil, let live = preview.program, let liveUniforms = preview.uniforms {
            program = live
            uniforms = liveUniforms
        } else {
            let shader: GeneratedShader
            do {
                shader = try ShaderGenerator.generate(document, target: document.settings.target, viewer: nil,
                                                      viewerPath: [], viewerDefinition: nil, registry: registry)
            } catch {
                return .failed("The graph has errors; fix them before recording.")
            }
            guard case .success(let pipeline) = await compiler.compile(shader, generation: 0, fastMath: document.settings.fastMath) else {
                return .failed("The shader failed to compile for recording.")
            }
            program = PreviewProgram(pipeline: pipeline, textures: bindings(for: pipeline))
            uniforms = UniformImage.rebuild(layout: pipeline.shader.layout, document: document, registry: registry)
        }
        let renderSize = kind == .video ? VideoSink.evenSize(size) : size
        viewState.lastExportSize = size
        let name = StitchableCodegen.sanitizedName(document.settings.exportName)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MetalNodes-recording-\(UUID().uuidString)")
        let output: URL
        let sink: any FrameSink
        let timeline: Timeline
        var spec = FrameSpec(time: 0, size: renderSize,
                             mouse: SIMD2(Float(renderSize.width) / 2, Float(renderSize.height) / 2),
                             orbit: preview.orbit, mesh: preview.mesh, viewerRange: 0...1)
        switch kind {
        case .video:
            output = scratch.appendingPathComponent("\(name).mp4")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            sink = VideoSink(url: output)
            timeline = document.settings.timeline
        case .imageSequence:
            output = scratch.appendingPathComponent(name)
            sink = ImageSequenceSink(directory: output, baseName: name)
            timeline = document.settings.timeline
        case .snapshot:
            output = scratch.appendingPathComponent("\(name).png")
            sink = ImageSequenceSink(directory: scratch, baseName: name, singleFileName: "\(name).png")
            timeline = Timeline(duration: 1.0 / Double(document.settings.timeline.frameRate),
                                frameRate: document.settings.timeline.frameRate, loops: false)
            spec.time = preview.clock.time
        }
        let session: ExportSession
        do {
            session = try ExportSession(device: device, program: program, uniforms: uniforms, spec: spec,
                                        timeline: timeline, sink: sink)
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            try await session.run { p in Task { @MainActor in progress(p) } }
        } catch RecordingError.cancelled {
            try? FileManager.default.removeItem(at: scratch)
            return .cancelled
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return .failed(error.localizedDescription)
        }
        let outcome = await destination.place(output, kind: kind, suggestedName: output.lastPathComponent)
        try? FileManager.default.removeItem(at: scratch)
        return outcome
    }
```

and to `EditorModel.swift`'s stored properties (next to `exportRequest`): `public private(set) var recordingRequest: RecordingKind?` and `public private(set) var recordingRequestCount = 0`. `bindings(for:)` at `EditorModel.swift:237` is `private`; make it internal (drop `private`) so the extension can call it. `compiler` and `registry` are the model's existing stored properties; `ShaderGenerator.generate(_:target:viewer:viewerPath:viewerDefinition:registry:)` is the call `generateResult` makes at `EditorModel.swift:744` — match its exact labels. The `generation: 0` pipeline is used only for this recording and never stored on `preview`.

- [ ] **Step 5: The sheets and the platforms**

`RecordingSheet.swift` (both platforms):

```swift
import SwiftUI
import CoreGraphics
import MetalNodesCore

/// Width × height, with the timeline read-only, then Record (spec §26.5).
struct RecordingSizeSheet: View {
    let kind: RecordingKind
    let timeline: Timeline
    let initialSize: CGSize
    let onRecord: (CGSize) -> Void
    let onCancel: () -> Void
    @State private var width: Int = 512
    @State private var height: Int = 512

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.headline)
            HStack {
                Text("Size")
                TextField("W", value: $width, format: .number).frame(width: 70)
                Text("×")
                TextField("H", value: $height, format: .number).frame(width: 70)
                Text("px").foregroundStyle(.secondary)
            }
            if kind != .snapshot {
                Text("\(timeline.frameCount) frames — \(timeline.duration, format: .number.precision(.fractionLength(1))) s at \(timeline.frameRate) fps. Change these in the Document section.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if kind == .video, width % 2 != 0 || height % 2 != 0 {
                Text("H.264 needs even dimensions; the video will be \(width + width % 2) × \(height + height % 2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Record") { onRecord(CGSize(width: max(width, 1), height: max(height, 1))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { width = Int(initialSize.width); height = Int(initialSize.height) }
    }
}

/// "Frame k of N" with Cancel.
struct RecordingProgressSheet: View {
    let progress: RecordingProgress?
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress?.frame ?? 0), total: Double(max(progress?.frameCount ?? 1, 1)))
            Text(progress.map { "Frame \($0.frame) of \($0.frameCount)" } ?? "Preparing…").font(.caption.monospacedDigit())
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(20)
        .frame(width: 280)
    }
}
```

`RecordingPanelMac.swift` (`#if os(macOS)`): an `NSSavePanel` for `.video`/`.snapshot` (`allowedContentTypes = [.mpeg4Movie]` / `[.png]`, `nameFieldStringValue = suggestedName`), moving the temporary file to the chosen URL with `FileManager.moveItem` (replacing an existing file after the panel's own overwrite confirmation); an `NSOpenPanel` folder chooser for `.imageSequence` (`canChooseDirectories`, `prompt = "Export"`, `message = "Choose a folder for the image sequence."`), moving the temporary directory to `<chosen>/<suggestedName>` and asking with the same `NSAlert` shape `ExportPanelMac.confirmReplace` uses when that folder already exists. Return `.saved` / `.cancelled` / `.failed(error.localizedDescription)`.

`RecordingDestinationPad.swift` (`#if os(iOS)`): an `@Observable final class RecordingDestinationPad: RecordingDestination` mirroring `ExporterPad` — it holds `pending: (wrapper: FileWrapper, name: String, isFolder: Bool)?` built with `try FileWrapper(url: temporary, options: .immediate)`, uses a `PickerPresenter<ExportOutcome>`, and a `RecordingDestinationPadHost` view modifier presents `.fileExporter(isPresented:document:contentType:defaultFilename:onCompletion:)` with a `nonisolated struct RecordingFileDocument: FileDocument` whose `readableContentTypes` is `[.png, .mpeg4Movie, .folder]` and whose `fileWrapper(configuration:)` returns the held wrapper. Add its host to `padHosts` the way `ExporterPadHost` is added (find `padHosts(` in `EditorView.swift`/`EditorViewPad.swift`).

**Presentation** (`EditorView.swift`): mirror the `exportRequest` block: `.onChange(of: model.recordingRequestCount)` sets `@State private var recordingKind: RecordingKind?`; `.sheet(item:)` on it shows `RecordingSizeSheet(kind:timeline: model.document.settings.timeline, initialSize: model.viewState.lastExportSize ?? model.document.settings.previewSize, …)`; on Record, dismiss it, set `@State private var recordingProgress: RecordingProgress?` and `@State private var recording = true`, present `RecordingProgressSheet` via `.sheet(isPresented: $recording)`, and run `model.recordingTask = Task { @MainActor in let outcome = await model.record(kind, size: size, device: device, destination: services.recordingDestination) { recordingProgress = $0 }; recording = false; if case .failed(let m) = outcome { exportError = m } }`; Cancel calls `model.recordingTask?.cancel()`. `EditorModel` gains `public var recordingTask: Task<Void, Never>?`. Reuse the existing "Export failed" alert for failures (rename its title to "Export failed" stays fine).

**Menus:** in `EditorCommands.swift`'s `CommandGroup(after: .saveItem)` add, after Export Shader…:

```swift
            Divider()
            ForEach(RecordingKind.allCases, id: \.self) { kind in
                Button("\(kind.title)…") { model?.requestRecording(kind) }
                    .disabled(model == nil)
            }
```

and in `EditorViewPad.swift`'s `exportMenu`, three `Button("\(kind.title)…") { model.requestRecording(kind) }` entries after "Export to Files…".

- [ ] **Step 6: Build both platforms, run the suites, mutate**

Run (repo root):
```bash
cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test 2>&1 | grep -E "warning:|error:|Test run with|failed"; cd ..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS' build -quiet 2>&1 | grep -E "warning:|error:"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build -quiet 2>&1 | grep -E "warning:|error:"
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```
Expected: no warnings anywhere; three `Test run with … passed` lines. Mutation: in `record`, skip the `exportFiles()` guard — `aDocumentThatDoesNotCompileIsRefusedBeforeAnyRenderer` FAILS; restore.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources MetalNodesKit/Tests
git commit -m "feat(recording): Export Video, Export Image Sequence and Snapshot PNG — size sheet, progress, platform destinations"
```

---

### Task 10: Execution record, live checks, memory (controller)

**Files:**
- Modify: `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` (new §17), `docs/superpowers/specs/2026-09-04-metalnodes-design.md` §26 (amendments if a ruling deviated)

Run by the controller after the final whole-branch review, with the app built and the screen unlocked.

- [ ] **Step 1: Live checks (spec §26.6)**

1. **Scrub:** new document; the preview row shows `1 / 240`, `0.00 s`, Loop on. Drag the slider: playback pauses, the counter and the picture follow; `,` and `.` step one frame; Space resumes from there; Reset returns to frame 1.
2. **Modes:** Fixed rate — the counter advances one per drawn frame and the picture is deterministic (pause, Reset, play: identical sequence). Wall clock — counter tracks real time; Loop off: the readout keeps counting past the end while the slider pins at the last frame.
3. **Timeline block:** set 2 s at 30 fps — "60 frames per loop"; a duration of 0 shows the notice and keeps the old value; ⌘Z reverts a timeline edit.
4. **Video:** File ▸ Export Video…, 640 × 360 → save; open in QuickTime Player: 2 s, plays the loop.
5. **Sequence:** File ▸ Export Image Sequence… into a folder: 60 PNGs named `metalNodesShader_0001.png…`; frame 1 and frame 60 differ.
6. **Snapshot:** scrub to mid-loop, File ▸ Snapshot PNG…: the PNG matches the pane.
7. **Cancel:** start a 4 s 60 fps 1920 × 1080 video, Cancel at ~frame 50: no file at the destination, no leftover `MetalNodes-recording-*` in `$TMPDIR`.
8. **RealityKit:** a material document records with the current orbit and mesh.

- [ ] **Step 2: Write handoff §17** — 17.1 what shipped (task → commits), 17.2 every ledger `Ruling:`, 17.3 the live checks with results, 17.4 what the reviews caught, 17.5 the M11 starting list (anything parked, plus §26's out-of-scope items as candidates).

- [ ] **Step 3: Memory and commit** — update `metalnodes-project-state.md` and the index; commit with the trailers.

---

## Self-review

**Spec coverage.** §26.2 → Tasks 1 (setting), 5 (inspector block, `setTimeline` refusal); §26.3 → Tasks 2 (clock), 3 (renderer + model sync), 5 (controls, shortcuts); §26.4 → Task 4; §26.5 → Tasks 6, 7, 8, 9 (sinks, session, destinations, sheet, menus, `lastExportSize`, even sizes, cancel cleanup, viewer flag never recorded); §26.6 → each task's tests plus Task 10's live checks; corpus untouched checked in Task 1.

**Placeholder scan.** No TBD/TODO. Task 3 and Task 9 each name one thing the implementer must read from an existing test file (the model/compiler construction helper) — a real instruction with the intent stated, not a placeholder; Task 9's macOS/iPad destination files are described by the existing `ExportPanelMac`/`ExporterPad` they mirror, with every behaviour named.

**Type consistency.** Test doubles are the existing `RecordingCompiler` and real `ShaderCompiler`; `TimelineClock.retarget(_:mode:)` (Task 2) is what `syncClock` calls (Task 3); `FrameSpec`'s six fields match between Tasks 4, 7 and 9; `FrameSink`'s four requirements are implemented by both sinks (Tasks 6, 8) and awaited by `ExportSession` (Task 7); `RecordingProgress(frame:frameCount:)` is 1-based in Task 7 and asserted so in Tasks 7 and 9; `ExportOutcome` is the existing enum; `RecordingKind.isFolder/fileExtension/title` are used by the sheet and destinations; `EditorModel.record(_:size:device:destination:progress:)` takes `MTLDevice?` as the refusal test requires.
