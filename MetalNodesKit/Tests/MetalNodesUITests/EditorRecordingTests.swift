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
        var last: RecordingProgress?
        let outcome = await m.record(.video, size: CGSize(width: 16, height: 16), device: device,
                                     destination: destination) { last = $0 }
        #expect(outcome == .saved)
        #expect(last == RecordingProgress(frame: 3, frameCount: 3))
        #expect(destination.placed.first?.url.pathExtension == "mp4")
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
