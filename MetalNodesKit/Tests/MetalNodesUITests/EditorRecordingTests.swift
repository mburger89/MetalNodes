import Testing
import CoreGraphics
import Foundation
import ImageIO
import Metal
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
        // retarget keeps the *time*, not the frame index (spec §27.5): frame 29 of the 1 s @ 30
        // fps clip is 0.967 s, which is frame 58 of the restored 4 s @ 60 fps timeline.
        #expect(m.preview.clock.frame == 58)
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

    /// Fixed rate with the loop off: the clock stopped itself at the last frame, and `step()`
    /// would stop it again on the very next draw — so Play there has to rewind first, or the
    /// button does nothing at all.
    @Test func playingFromTheEndOfANonLoopingFixedRateClipRestartsIt() {
        let m = model()
        var s = m.document.settings
        s.timeline = Timeline(duration: 0.1, frameRate: 30, loops: false)   // 3 frames
        s.timeMode = .fixedRate
        m.apply(.setSettings(s))
        m.scrub(to: 2)
        #expect(m.preview.clock.frame == 2 && !m.preview.clock.isPlaying)
        m.togglePlayback()
        #expect(m.preview.clock.frame == 0)
        #expect(m.preview.clock.isPlaying)
    }

    /// Only the end rewinds: resuming from anywhere else keeps the frame it was paused on.
    @Test func playingFromTheMiddleKeepsTheFrame() {
        let m = model()
        var s = m.document.settings
        s.timeline = Timeline(duration: 0.1, frameRate: 30, loops: false)   // 3 frames
        s.timeMode = .fixedRate
        m.apply(.setSettings(s))
        m.scrub(to: 1)
        m.togglePlayback()
        #expect(m.preview.clock.frame == 1)
        #expect(m.preview.clock.isPlaying)
    }
}

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

    /// `Timeline.frameCount` multiplies by the frame rate and converts to `Int`, which traps on a
    /// non-finite or astronomical duration — so the guard is a range, not just `> 0`.
    @Test(arguments: [Double.infinity, 1e9, Double.nan, 3601])
    func aDurationThatWouldTrapFrameCountIsRefused(_ bad: Double) {
        let m = model()
        m.setTimeline(Timeline(duration: bad, frameRate: 60, loops: true))
        #expect(m.document.settings.timeline == Timeline())
        #expect(m.notice == "Duration must be between 0 and 3600 seconds")
        #expect(!m.canUndo)
    }

    /// The upper bound is inclusive — an hour-long timeline is unusual but legal.
    @Test func anHourLongTimelineIsAccepted() {
        let m = model()
        m.setTimeline(Timeline(duration: 3600, frameRate: 24, loops: false))
        #expect(m.document.settings.timeline.duration == 3600)
        #expect(m.notice == nil)
    }
}

/// The Duration field commits its text once, on Return — `TextField(value:)` used to commit every
/// keystroke, so "5000" applied 5, 50 and 500 on the way past. SwiftUI's `TextField` itself is not
/// unit-testable here; the parse step it now goes through is.
@Suite struct TimelineFieldParserTests {
    @Test func aPlainDecimalParses() {
        #expect(TimelineFieldParser.duration(from: "2.5") == 2.5)
    }

    /// Out of range is not the parser's business: it hands 5000 on, and `setTimeline` is what
    /// refuses it (see `aDurationThatWouldTrapFrameCountIsRefused`). Same for exponent form —
    /// "1e9" parses to 1e9 and is refused there, rather than being silently swallowed here.
    @Test(arguments: [("5000", 5000.0), ("1e9", 1e9), ("3600", 3600.0), ("0", 0.0), ("-1", -1.0)])
    func aNumberOutOfRangeStillParsesAndIsTheModelsToRefuse(_ text: String, _ expected: Double) {
        #expect(TimelineFieldParser.duration(from: text) == expected)
    }

    /// Not a number: the field resets and nothing happens — no notice, no undo step.
    @Test(arguments: ["abc", "", " ", "5s", "1,5"])
    func textThatIsNotANumberIsRejected(_ text: String) {
        #expect(TimelineFieldParser.duration(from: text) == nil)
    }
}

@Suite struct RecordingProgressFractionTests {
    /// Before the first frame is reported there is nothing to show.
    @Test func noProgressIsAnEmptyBar() {
        #expect(RecordingProgressSheet.fraction(nil) == 0)
    }

    /// The frame is 1-based, so the last frame fills the bar.
    @Test func theFractionTracksTheFrame() {
        #expect(RecordingProgressSheet.fraction(RecordingProgress(frame: 1, frameCount: 4)) == 0.25)
        #expect(RecordingProgressSheet.fraction(RecordingProgress(frame: 120, frameCount: 240)) == 0.5)
        #expect(RecordingProgressSheet.fraction(RecordingProgress(frame: 4, frameCount: 4)) == 1)
    }

    @Test func anImpossibleCountDoesNotDivideByZero() {
        #expect(RecordingProgressSheet.fraction(RecordingProgress(frame: 3, frameCount: 0)) == 0)
        #expect(RecordingProgressSheet.fraction(RecordingProgress(frame: 9, frameCount: 4)) == 1)
    }
}

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
        m.start()
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
        m.scrub(to: 30)                                               // 30 / 60 fps → t = 0.5 → red ≈ 128
        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
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
        m.scrub(to: 30)
        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
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
        await m.awaitIdle()
        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
        // Every hop back to the main actor is awaited by the session's loop, so the reports arrive
        // in frame order — the last one is what takes the progress sheet down.
        var seen: [RecordingProgress] = []
        let outcome = await m.record(.video, size: CGSize(width: 16, height: 16), device: device,
                                     destination: destination) { seen.append($0) }
        #expect(outcome == .saved)
        #expect(seen == (1...3).map { RecordingProgress(frame: $0, frameCount: 3) })
        #expect(destination.placed.first?.url.pathExtension == "mp4")
    }

    @MainActor
    @Test func anImageSequenceIsAFolderOfNumberedFrames() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let m = try await compiledModel(device)
        m.setTimeline(Timeline(duration: 0.1, frameRate: 30, loops: true))     // 3 frames
        await m.awaitIdle()
        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
        let outcome = await m.record(.imageSequence, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .saved)
        let placed = try #require(destination.placed.first)
        #expect(placed.kind == .imageSequence)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: placed.url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "an image sequence is placed as a folder")
        let name = StitchableCodegen.sanitizedName(m.document.settings.exportName)
        let files = try FileManager.default.contentsOfDirectory(atPath: placed.url.path).sorted()
        #expect(files == (1...3).map { String(format: "%@_%04d.png", name, $0) })
    }

    /// A compile failure keeps the last good pipeline live (spec §19.1), so a graph that has
    /// stopped generating still has a `preview.program`: the refusal has to come from `exportFiles()`.
    @MainActor
    @Test func aGraphThatStoppedGeneratingIsRefusedEvenWithALiveProgram() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let m = try await compiledModel(device)
        let terminal = try #require(m.document.root.nodes.values.first { $0.kind == .builtin("output.fragment") })
        m.apply(.removeNodes([terminal.id]))
        await m.awaitIdle()
        #expect(m.preview.program != nil, "the last good program is still live")
        let destination = MemoryRecordingDestination()
        let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .failed("The graph has errors; fix them before recording."))
        #expect(destination.placed.isEmpty)
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

/// The gate `record` puts in front of every recording (spec §27.6): the document's *current*
/// program or nothing. The two ways the live program can disagree with the document — a Metal
/// compile that failed after one succeeded, and an edit still inside its debounce — each get a
/// test, because each is closed by a different line of the gate.
@MainActor
@Suite struct RecordingGateTests {
    /// The formula the fixture ships with, and a different one that still generates: swapping them
    /// changes the generated source, so `compileNow` cannot take its same-source shortcut.
    private static let editedFormula = ParamValue.text("float4(t, 0.0, 0.25, 1.0)")

    private func expressionNode(_ m: EditorModel) throws -> NodeInstance {
        try #require(m.document.root.nodes.values.first { $0.kind == .builtin("utility.expression") })
    }

    /// The stale-program case (editor finding 1, render finding 2). Generation still succeeds — a
    /// bad Custom Code body is MSL the codegen never reads — so `exportFiles()` says yes and the
    /// last-good pipeline is still live. Only `preview.lastError` knows the truth.
    @Test func aGraphWhoseMetalCompileFailsIsRefusedEvenThoughItStillGenerates() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let compiler = try SwitchableCompiler(device: device)
        let m = EditorModel(document: ExportSessionFixture.timeDocument(), compiler: compiler)
        m.debounceInterval = .milliseconds(5)
        m.start()
        await m.awaitIdle()
        #expect(m.preview.program != nil)

        await compiler.setFailing(true)
        m.apply(.setParam(try expressionNode(m).id, "formula", Self.editedFormula))
        await m.awaitIdle()
        #expect(m.preview.program != nil, "the last good program is still live (spec §19.1)")
        #expect((try? m.exportFiles()) != nil, "the graph still generates")
        #expect(m.preview.lastError != nil)

        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
        let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .failed("The graph has errors; fix them before recording."))
        #expect(destination.placed.isEmpty)
    }

    /// The pending-compile window: the edit is still inside its debounce when Record is chosen, so
    /// nothing about it has reached `preview` yet. `record` must settle it first and then judge —
    /// without the `awaitIdle()` this records the pre-edit program and answers `.saved`.
    @Test func recordingSettlesAnInFlightCompileBeforeItDecides() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let compiler = try SwitchableCompiler(device: device)
        let m = EditorModel(document: ExportSessionFixture.timeDocument(), compiler: compiler)
        m.debounceInterval = .milliseconds(200)
        m.start()
        await m.awaitIdle()
        #expect(m.preview.program != nil)

        await compiler.setFailing(true)
        m.apply(.setParam(try expressionNode(m).id, "formula", Self.editedFormula))
        // Deliberately no `awaitIdle()` here: the debounce is still running, so `preview.lastError`
        // is nil and `preview.program` is the pre-edit pipeline at the moment `record` is called.
        #expect(m.preview.lastError == nil)
        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
        let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .failed("The graph has errors; fix them before recording."))
        #expect(destination.placed.isEmpty)
        #expect(m.preview.lastError != nil, "record waited for the compile it triggered")
    }

    /// The other half of the same behaviour: settling a pending compile must not make a good
    /// document unrecordable, and `awaitIdle()` must return rather than hang on the debounce.
    @Test func aPendingEditThatCompilesStillRecords() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        let m = EditorModel(document: ExportSessionFixture.timeDocument(), compiler: try ShaderCompiler(device: device))
        m.debounceInterval = .milliseconds(200)
        m.start()
        await m.awaitIdle()
        m.apply(.setParam(try expressionNode(m).id, "formula", Self.editedFormula))
        let destination = MemoryRecordingDestination()
        defer { destination.cleanUp() }
        let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device,
                                     destination: destination) { _ in }
        #expect(outcome == .saved)
        #expect(m.diagnostics.isEmpty)
        #expect(destination.placed.count == 1)
    }

    /// A recording outlives neither its window nor its document (editor finding 3, spec §27.6).
    @Test func reloadingCancelsARunningRecording() {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        m.recordingTask = task
        #expect(m.isRecording)
        m.reload(package: ShaderPackage(document: .sample()))
        #expect(task.isCancelled)
        #expect(!m.isRecording)
        #expect(m.recordingTask == nil)
    }

    /// `isRecording` is the observed mirror the menus disable on; `recordingTask` itself is not
    /// observed, so the two must never drift.
    @Test func isRecordingMirrorsTheTask() {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        #expect(!m.isRecording)
        m.recordingTask = Task<Void, Never> {}
        #expect(m.isRecording)
        m.recordingTask = nil
        #expect(!m.isRecording)
    }
}

/// What the size sheet accepts (editor finding 7, spec §27.6): a video is bounded by H.264's own
/// ceiling, an image by the export pixel budget — two different limits and two different messages.
@MainActor
@Suite struct RecordingSizeSheetBoundsTests {
    @Test func videoAndImagesAreBoundedDifferently() {
        // 16384 × 4096 is 67,108,864 pixels — exactly the image budget, and far past H.264's edge.
        #expect(RecordingSizeSheet.isValid(kind: .snapshot, width: 16384, height: 4096))
        #expect(!RecordingSizeSheet.isValid(kind: .video, width: 16384, height: 4096))
        // 8K is inside level 6.2 (33.2 of 35.6 megapixels).
        #expect(RecordingSizeSheet.isValid(kind: .video, width: 7680, height: 4320))
        // One pixel column past the image budget, with both edges inside `maxDimension`.
        #expect(!RecordingSizeSheet.isValid(kind: .imageSequence, width: 8193, height: 8192))
        #expect(RecordingSizeSheet.isValid(kind: .imageSequence, width: 8192, height: 8192))
        #expect(!RecordingSizeSheet.isValid(kind: .video, width: 0, height: 10))
        #expect(!RecordingSizeSheet.isValid(kind: .snapshot, width: 10, height: 0))
    }

    /// The caption names the limit the user just hit, so the two kinds cannot share one string.
    @Test func theLimitTextNamesEachKindsCeiling() {
        #expect(RecordingSizeSheet.limitText(for: .video).contains("8192"))
        #expect(RecordingSizeSheet.limitText(for: .video).contains("35.6"))
        #expect(RecordingSizeSheet.limitText(for: .snapshot).contains("\(ExportSession.maxPixels)"))
        #expect(RecordingSizeSheet.limitText(for: .snapshot) == RecordingSizeSheet.limitText(for: .imageSequence))
        #expect(RecordingSizeSheet.limitText(for: .video) != RecordingSizeSheet.limitText(for: .snapshot))
    }
}
