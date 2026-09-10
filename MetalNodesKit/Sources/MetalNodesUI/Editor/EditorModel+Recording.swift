import CoreGraphics
import Foundation
import Metal
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

    /// Play/Pause. A non-looping clock parked on its last frame is the one case where flipping
    /// `isPlaying` alone does nothing: `TimelineClock.step()` would see the end again on the very
    /// next draw and stop straight away, so Play there means play the clip again from the top.
    /// Only `.fixedRate` needs it — the wall clock re-seeks from `pausedElapsed` instead.
    public func togglePlayback() {
        if !preview.clock.isPlaying, preview.clock.mode == .fixedRate,
           !preview.clock.timeline.loops, preview.clock.frame == preview.clock.timeline.frameCount - 1 {
            resetPlayback()
        }
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
    /// A duration that is not a sane number of seconds is refused outright: `Timeline.frameCount`
    /// multiplies by the frame rate and converts to `Int`, which traps on a non-finite or
    /// astronomical duration, so the guard has to be an upper bound and not just `> 0`.
    public func setTimeline(_ timeline: Timeline) {
        guard timeline.duration > 0, timeline.duration.isFinite, timeline.duration <= 3600 else {
            showNotice("Duration must be between 0 and 3600 seconds")
            return
        }
        var s = document.settings
        s.timeline = timeline
        apply(.setSettings(s))
    }

    // MARK: Recording (spec §26.5)

    /// Bumped by the File menu; the view presents the size sheet on change.
    public func requestRecording(_ kind: RecordingKind) { recordingRequest = kind; recordingRequestCount += 1 }

    /// Renders the document's program at `size` and places the result (spec §26.5). Refuses a graph
    /// that does not generate, or does not compile, before any renderer is built. Runs the session
    /// off the main actor; `progress` is delivered on it.
    public func record(_ kind: RecordingKind, size: CGSize, device: MTLDevice?,
                       destination: any RecordingDestination,
                       progress: @escaping @MainActor @Sendable (RecordingProgress) -> Void) async -> ExportOutcome {
        // The last-good pipeline is never recorded in place of the document's program (spec §27.6).
        // `exportFiles()` only proves the graph *generates*; a Metal compile that failed afterwards
        // leaves `preview.program` at the pipeline from before the failing edit, and an edit still
        // inside its debounce has not reached `preview` at all. So settle any pending compile
        // first, then refuse on any error the editor is already showing.
        await awaitIdle()
        guard (try? exportFiles()) != nil, preview.lastError == nil,
              !diagnostics.contains(where: { $0.severity == .error }), preview.program != nil else {
            return .failed("The graph has errors; fix them before recording.")
        }
        guard let device else { return .failed(RecordingError.noDevice.errorDescription ?? "No Metal device") }
        // `nonisolated(unsafe)` for the same reason `ExportSession` stores it that way: a
        // `PreviewProgram` holds `MTLTexture`s and predates `Sendable`, so it cannot cross into the
        // actor on its own. It is built here on the main actor, only read from then on, and Metal
        // textures are safe to read from any thread.
        nonisolated(unsafe) let program: PreviewProgram
        let uniforms: UniformImage
        // The viewer flag is never recorded (spec §26.5). With no viewer the live program *is* the
        // document's; with one set, compile the document's program once for this recording.
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
        // H.264 refuses odd dimensions, so a video renders at the rounded-up size; every other kind
        // renders at exactly what the sheet asked for. `ExportSession` rounds `spec.size` for its
        // textures but leaves the uniform alone, so the size handed in is already integral.
        let renderSize = kind == .video ? VideoSink.evenSize(size) : size
        viewState.lastExportSize = size
        let name = StitchableCodegen.sanitizedName(document.settings.exportName)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MetalNodes-recording-\(UUID().uuidString)")
        let output: URL
        let sink: any FrameSink
        let timeline: Timeline
        // The mouse is normalized (0...1), the way the live preview writes it — the centre of frame.
        var spec = FrameSpec(time: 0, size: renderSize, mouse: SIMD2(0.5, 0.5),
                             orbit: preview.orbit, mesh: preview.mesh, viewerRange: 0...1)
        switch kind {
        case .video:
            output = scratch.appendingPathComponent("\(name).\(kind.fileExtension)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            sink = VideoSink(url: output)
            timeline = document.settings.timeline
        case .imageSequence:
            output = scratch.appendingPathComponent(name)
            sink = ImageSequenceSink(directory: output, baseName: name)
            timeline = document.settings.timeline
        case .snapshot:
            let file = "\(name).\(kind.fileExtension)"
            output = scratch.appendingPathComponent(file)
            sink = ImageSequenceSink(directory: scratch, baseName: name, singleFileName: file)
            timeline = Timeline(duration: 1.0 / Double(document.settings.timeline.frameRate),
                                frameRate: document.settings.timeline.frameRate, loops: false)
            spec.time = preview.clock.time
        }
        let session: ExportSession
        do {
            session = try ExportSession(device: device, program: program, uniforms: uniforms, spec: spec,
                                        timeline: timeline, sink: sink)
        } catch {
            // `.video` has already created the scratch directory for the writer.
            try? FileManager.default.removeItem(at: scratch)
            return .failed(error.localizedDescription)
        }
        do {
            // Awaited, not spawned: one `Task` per frame would deliver the hops in whatever order
            // the main actor happened to run them, and the last hop is what dismisses the sheet.
            try await session.run { p in await MainActor.run { progress(p) } }
        } catch is CancellationError {
            // A sink that learns to cancel on its own would throw this rather than the session's own
            // `RecordingError.cancelled`; both are the same outcome to the sheet.
            try? FileManager.default.removeItem(at: scratch)
            return .cancelled
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
}

/// The Duration field's text step, kept out of the view so it can be tested: SwiftUI's own
/// `TextField` cannot be (spec §26.2).
///
/// Deliberately as forgiving as `Int(_:)` is for the preview-size fields and no more — it decides
/// only whether the text *is* a number, never whether that number is a usable duration.
/// `EditorModel.setTimeline` owns the bounds (and the notice a bad one raises), so `"1e9"` parses
/// here and is refused there; `"abc"` is not a number at all, so the field simply resets with no
/// notice. Locale is not consulted, for the same reason the preview-size fields don't: the draft is
/// seeded from `"\(Double)"`, which always writes a `.`, so a comma would never round-trip.
enum TimelineFieldParser {
    static func duration(from text: String) -> Double? { Double(text) }
}
