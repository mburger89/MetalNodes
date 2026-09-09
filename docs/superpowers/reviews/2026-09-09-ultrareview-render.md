# MetalNodesRender — deep review (M10 recording pipeline + live renderer)

Scope: `MetalNodesKit/Sources/MetalNodesRender/**` at `51ce762`, its tests, and the two front ends that drive it (`ShaderRenderer.draw(in:)` on the main actor; `ExportSession.run` off it, called from `MetalNodesUI/Editor/EditorModel+Recording.swift`). Read-only. Claims marked **confirmed** were verified either by tracing the code path end to end or by a throwaway probe compiled outside the repo (`scratchpad/ultrareview/probe/{big,late}.swift`, run against this machine's AVFoundation/VideoToolbox).

Counts: **critical 0 · high 1 · medium 5 · low 10** (+ one informational note on the concurrency annotations).

---

## 1. H.264 export at sheet-accepted sizes renders every frame, then fails at `finishWriting`

- **Severity:** high · **Category:** bug · **Confidence:** confirmed (probe)
- **Where:** `Sources/MetalNodesRender/Recording/VideoSink.swift:27-49` (`begin`), `:88-103` (`finish`); `Sources/MetalNodesUI/Editor/RecordingSheet.swift:21-23` (validity is `1...ExportSession.maxDimension` for every kind, including video)

**Scenario.** The sheet promises "Width and height must be between 1 and 16384 px" for a video too. The H.264 encoder on this machine (Apple silicon, macOS 26) accepts *every* `append` — `adaptor.append` returns `true` and `writer.status` stays `.writing` — and only `finishWriting` reports the failure:

| size | pixels | `finishWriting` status |
|---|---|---|
| 5120×5120 | 26.2 MP | `.completed` |
| 7680×4320 | 33.2 MP | `.completed` |
| 8192×4320 | 35.4 MP | `.completed` |
| 6144×6144 | 37.7 MP | `.failed` (-11800 / OSStatus -10279) |
| 8192×8192, 16384×16384 | | `.failed` |

That ceiling is H.264 level 6.2's 139 264 macroblocks (≈35.65 MP). So a user who asks for a 6144² or 8K-square video renders all `frameCount` frames (minutes at that size), watches the bar reach the end, and then gets the alert "The video writer failed: The operation could not be completed" — nothing about size, and `RecordingError.sizeUnsupported` (which exists for exactly this) is never produced because `ExportSession.init` only knows Metal's 16384 texture edge.

**Fix.** Fail before the first frame, and name the cause:

```swift
// VideoSink.begin, after the writer is configured — a one-frame throwaway session at the
// target size. Costs ~100 ms; a size the encoder cannot finish fails here, not after the render.
static func preflight(width: Int, height: Int, settings: [String: Any]) throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mn-preflight-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let w = try AVAssetWriter(outputURL: scratch, fileType: .mp4)
    let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [...])
    w.add(i); guard w.startWriting() else { throw ... }
    w.startSession(atSourceTime: .zero)
    var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, a.pixelBufferPool!, &b)
    _ = a.append(b!, withPresentationTime: .zero); i.markAsFinished()
    await w.finishWriting()   // (make preflight async)
    guard w.status == .completed else { throw RecordingError.sizeUnsupported(CGSize(width: width, height: height)) }
}
```

Cheaper alternative: cap video in the sheet at level 6.2 (`w <= 8192 && h <= 8192 && w*h <= 35_651_584`) and say so in the caption, or fall back to `.hevc` above the cap (HEVC hardware on Apple silicon encodes 8192² fine). Either way, `ExportSession.maxDimension` should not be the video bound.

---

## 2. A recording can capture the previous, last-good program while the editor shows a compile error

- **Severity:** medium · **Category:** bug (caller contract) · **Confidence:** confirmed (code path)
- **Where:** `Sources/MetalNodesUI/Editor/EditorModel+Recording.swift:81-95`; the keep-last-good behaviour is `EditorModel.swift:676-688` (`.failure` sets `preview.lastError` and does *not* `publish`), and `:641-642` for generation failures

**Scenario.** A Custom Code node with an MSL error: `ShaderGenerator.generate` succeeds (generation does not compile MSL), `compiler.compile` fails, `preview.lastError` is set, the diagnostics list shows the error, and `preview.program` stays at the last pipeline that *did* compile. `record` guards on `(try? exportFiles()) != nil, preview.program != nil` — both true — and, with no viewer set, takes `program = live`. The export silently renders the older graph with `preview.uniforms` (rebuilt for that older layout), and the user gets a file that does not match the editor. The same window exists for any edit inside the 150 ms debounce plus compile time: `record` never awaits `awaitIdle()`, so an edit made just before File ▸ Export records the pre-edit program.

**Fix.**

```swift
await awaitIdle()                                   // settle the debounce + in-flight compile
guard (try? exportFiles()) != nil, preview.program != nil, preview.lastError == nil else {
    return .failed("The graph has errors; fix them before recording.")
}
```

(`awaitIdle` already exists at `EditorModel.swift:313`.)

---

## 3. Preview is not colour-managed, the export is: the two disagree on every P3 display

- **Severity:** medium · **Category:** bug · **Confidence:** confirmed mechanism (SDK docs); visible magnitude depends on the panel
- **Where:** `Sources/MetalNodesRender/PreviewView.swift:16-31` (no `colorspace` set); `Recording/FrameSink.swift:61-62` (PNG tagged `CGColorSpace.sRGB`); `Recording/VideoSink.swift:31-35` (no `AVVideoColorPropertiesKey`)

**Scenario.** `MTKView` leaves its `CAMetalLayer.colorspace` nil, and `CAMetalLayer.h` is explicit: *"If nil, no colormatching occurs."* The preview therefore shows the shader's raw bytes as the display's native primaries — Display P3 on every current Mac and iPad. `ImageSequenceSink.cgImage` tags the same bytes sRGB, so Preview/Finder/browsers colour-match them into P3 and the PNG looks visibly less saturated than the live preview. The `.mp4` carries no `colr` atom at all (no `AVVideoColorPropertiesKey`, no attachments on the pixel buffers), so each player guesses (601 vs 709 matrix by resolution heuristics), and the H.264 file can differ from both the preview *and* the PNG.

**Fix.** Make the preview interpret bytes the same way the files are tagged:

```swift
// PreviewView.makeView
#if os(macOS)
v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)            // MTKView.colorspace, macOS
#else
(v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
#endif
```

and tag the video:

```swift
AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
```

(709 primaries are sRGB's; the transfer curves differ slightly but this is the conventional tag for sRGB-authored SDR video.)

---

## 4. Export is fully serial: three full-frame copies and no overlap between GPU, readback and encoding

- **Severity:** medium · **Category:** perf · **Confidence:** confirmed (argued from the code; costs are estimates)
- **Where:** `Recording/ExportSession.swift:96-104` (loop), `:130-136` (`waitUntilCompleted`, then `Array(UnsafeRawBufferPointer…)`), `Recording/FrameSink.swift:42-51, 63` (`Data(frame.bgra)` + synchronous `CGImageDestinationFinalize`), `Recording/VideoSink.swift:76-80` (row memcpy into the pool buffer)

**Cost.** Per frame: render → block the actor's cooperative thread in `waitUntilCompleted` → copy `readback` into a fresh `[UInt8]` (8 MB at 1080p, 33 MB at 4K) → for PNG, copy again into `Data`, then encode single-threaded on the actor (tens of ms at 1080p, roughly half a second at 4K) → only then encode the next frame. The GPU idles during encoding and the CPU idles during rendering. A 240-frame 4K sequence is on the order of two minutes of ImageIO doing one frame at a time on one core.

**Fix (in order of payoff).**
1. Encode PNGs concurrently: keep the render loop as is but hand each `FrameBytes` to a bounded `TaskGroup` (width ≈ `ProcessInfo.processInfo.activeProcessorCount`) and await the group at the end; ordering is by `index`, which the sink already takes. Cancellation semantics stay (the group is cancelled with the task).
2. Double-buffer the readback: two `readback` buffers, `addCompletedHandler` resuming a continuation instead of `waitUntilCompleted`, so frame k+1's GPU work overlaps frame k's sink write.
3. Video only: render into a texture created from the adaptor's `CVPixelBuffer` via `CVMetalTextureCache` (`.bgra8Unorm`, shared) — no blit, no `[UInt8]`, no memcpy.

---

## 5. Fixed-rate playback runs at the display's rate, not the timeline's — a 24 fps document previews at 2.5×

- **Severity:** medium · **Category:** improvement (spec-consistent behaviour, but the preview misrepresents the recording) · **Confidence:** confirmed
- **Where:** `Sources/MetalNodesRender/ShaderRenderer.swift:54-61`; `PreviewView.swift:27` (`preferredFramesPerSecond = 60`, unconditional)

**Scenario.** Spec §26.2 says `.fixedRate` "advances exactly one frame per drawn frame", and the handoff live check measured 60 frames/s at 60 Hz. The view always asks for 60 draws/s, so a 24 fps timeline steps 60 frames per second: the preview plays at 2.5× (30 fps at 2×), while the exported video of the same document plays at 1×. The user's only real-time view of a fixed-rate clip is wrong-speed.

**Fix.** Keep "one frame per draw" and make the draw rate the timeline rate in that mode — `updateNSView`/`updateUIView` are currently empty:

```swift
public func updateNSView(_ view: MTKView, context: Context) {
    view.preferredFramesPerSecond = state.clock.mode == .fixedRate ? state.clock.timeline.frameRate : 60
}
```

(Scrub repaint still happens at that rate; the spec's "display link keeps running while paused" holds.)

---

## 6. Memory at the allowed maximum is ~5 GiB and nothing refuses it

- **Severity:** medium · **Category:** improvement · **Confidence:** plausible (arithmetic; not run at 16384²)
- **Where:** `Recording/ExportSession.swift:61-78` (colour + depth private textures, readback buffer), `:136` (`[UInt8]` copy), `FrameSink.swift:63` (`Data` copy)

**Cost.** At 16384² a single snapshot allocates 1 GiB colour + 1 GiB depth (allocated even for 2D programs because every pipeline declares the attachment) + 1 GiB readback + 1 GiB `[UInt8]` + 1 GiB `Data` for ImageIO. Metal allocates private textures lazily, so `makeTexture` will not return nil and `sizeUnsupported` never fires; the process is jetsammed instead on an 8 GB machine.

**Fix.** Depth attachment is cleared and `.dontCare`-stored, so on Apple GPUs make it memoryless (`d.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private`) — zero bytes. Then either bound the frame by pixel count (e.g. 64 MP, still 8K×8K) or compare `w*h*4*3` against `device.recommendedMaxWorkingSetSize` in `init` and throw `sizeUnsupported`. Items 4.2/4.3 above remove the two CPU copies.

---

## 7. No `endSession` — a one-frame video is 1/15 s long, not 1/fps

- **Severity:** low · **Category:** bug · **Confidence:** confirmed (probe: one frame at 64², no `endSession`, `.duration` = 0.0667 s)
- **Where:** `Recording/VideoSink.swift:88-103`

**Scenario.** Timeline duration ≤ 1.5/fps (e.g. 0.02 s at 60 fps) gives `frameCount == 1`. With no `endSession(atSourceTime:)` the writer infers the last sample's duration from the previous delta; with one sample there is none and it defaults to 1/15 s. For N ≥ 2 frames the inference happens to be right (the 12-frame test's 0.2 s), so this is only the degenerate case — but the fix also makes every file's duration exactly `frameCount / frameRate` by construction rather than by inference.

**Fix.** Track the last index written (`private var lastIndex = -1` under `queue`) and before `markAsFinished`: `writer.endSession(atSourceTime: CMTime(value: CMTimeValue(lastIndex + 1), timescale: CMTimeScale(frameRate)))`.

---

## 8. `VideoSink.finish()` / `abandon()` do not check writer status; `finish` after `abandon` is an uncatchable NSException

- **Severity:** low (latent — not reachable from `ExportSession.run` today) · **Category:** bug · **Confidence:** confirmed (probe crashed with `-[AVAssetWriterHelper _transitionToClientInitiatedTerminalStatus:]` NSException)
- **Where:** `Recording/VideoSink.swift:92-98` (`markAsFinished` + `finishWriting` guarded only by `writer != nil`), `:106-108` (`cancelWriting` unconditionally)

**Scenario.** `run` calls exactly one of `finish`/`abandon`, so the shipped flow is safe, and the probe also showed the *asynchronous* `.failed` transition (writer fails between the last `append` and `finish`, as the 8192² case does) is handled: `markAsFinished`/`finishWriting` survive and `finish()` throws `writerFailed`. But `FrameSink` is a public protocol with three implementations expected, `VideoSink` is public, and `finishWriting` on a cancelled writer (or a second `cancelWriting`) terminates the process rather than throwing.

**Fix.** In both methods, read `writer.status` inside `queue.sync` and only act when it is `.writing`; make `abandon` idempotent (`writer = nil` after cancelling).

---

## 9. `ExportSession.init` traps on a large negative size

- **Severity:** low · **Category:** bug · **Confidence:** confirmed (reading; only reachable via the API — the sheet clamps to ≥ 1)
- **Where:** `Recording/ExportSession.swift:53-60`

`width = -1e300` is finite and `<= maxDimension`, so the guard passes and `Int(spec.size.width.rounded())` traps before `max(1, …)` can clamp it. Guard `abs(spec.size.width.rounded()) <= CGFloat(Self.maxDimension)` (same for height).

---

## 10. Snapshot mode is inferred from `count == 1 && spec.time != 0`

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `Recording/ExportSession.swift:95-99`; caller `EditorModel+Recording.swift:133-139`

A one-frame *video* whose template time is non-zero would silently become a snapshot at that time; a snapshot at frame 0 works only because `0/fps == 0`. Make the two shapes explicit — `enum Frames { case timeline(Timeline); case single(time: Float, frameRate: Int) }` — and drop the sentinel.

---

## 11. `%04d` frame names stop sorting past frame 9999

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `Recording/FrameSink.swift:44`; the bound that allows it is `EditorModel+Recording.swift:61` (duration ≤ 3600 s → up to 216 000 frames at 60 fps)

`clip_10000.png` sorts before `clip_9999.png` lexically, which is what most importers (and Finder) use. Pad to `max(4, String(frameCount).count)`; `begin(width:height:frameRate:)` can grow a `frameCount:` parameter so the sink knows the width up front.

---

## 12. Live view holds a drawable while blocked on the in-flight semaphore; export command buffers can starve it

- **Severity:** low · **Category:** perf · **Confidence:** plausible
- **Where:** `ShaderRenderer.swift:30-33` (`currentDrawable` before `inflight.wait()` at `:67`)

The usual order is wait → acquire drawable, so a blocked frame does not also pin one of the layer's (default 3) drawables. Separately, during a large export the preview keeps drawing at 60 Hz on its own queue; its three-deep semaphore can then block the main thread behind multi-hundred-millisecond export command buffers, which is the Cancel button's thread. `view.isPaused = true` for the life of `recordingTask` (or `preferredFramesPerSecond = 10`) would keep the sheet responsive. Not measured.

---

## 13. Synchronous work on the main thread: texture decode and the vertex-stage compile

- **Severity:** low · **Category:** perf · **Confidence:** confirmed (reading)
- **Where:** `TextureStore.swift:43-50` (`MTKTextureLoader.newTexture(data:)` — synchronous decode on `@MainActor`, and `evictAll` + `reload` re-decodes every texture at once); `ShaderCompiler.swift:108-110` (`device.makeLibrary(source:)` synchronous in `init`, which `DocumentHostView` calls on the main thread at document open)

A 4K PNG decode is tens of ms; a Revert To Saved with several is a visible hitch. Use `MTKTextureLoader.newTexture(data:options:)` async variant and publish bindings when it lands (the placeholder already covers the gap); compile the vertex library in a detached task at first use.

---

## 14. Progress sheet closes before `sink.finish()`; the app is silently modal until it returns

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed (reading)
- **Where:** `Sources/MetalNodesUI/Editor/EditorView.swift:84-86` (`if p.frame >= p.frameCount { recordingPhase = nil }`); `ExportSession.swift:103-105` (last report precedes `finish`)

`finishWriting` flushes the encoder — seconds for a long 4K H.264 — with no sheet, no Cancel, and `recordingTask != nil` so File ▸ Export… commands do nothing. On macOS dismiss after `run` returns; on the iPad (where the early dismissal exists for the `fileExporter` presentation) report a final "Finishing…" state instead.

---

## 15. Wall-clock mode writes the observable `clock` on draws where nothing visible changed

- **Severity:** low · **Category:** perf · **Confidence:** confirmed (reading)
- **Where:** `ShaderRenderer.swift:49` (`state.clock.seek(elapsed:)` every draw); `PreviewState.swift:28`

`seek` always assigns `elapsedSeconds`, so `clock` (an `@Observable` property) is written 60×/s and `PlaybackControls` re-evaluates at 60 Hz even for a 24 fps timeline whose `frame` changes 24×/s. `TimelineClock` is `Equatable`: compute into a local and assign only on change (the same guard the `.fixedRate` branch already applies to `playStartedAt`).

---

## 16. Every encode failure is reported as "The video writer failed …", including PNG exports

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `Recording/ExportSession.swift:121-126`, `:135` (`cmd.error` also mapped to `writerFailed`)

Add `RecordingError.encodeFailed`/`.gpuError(String)` so the alert does not blame a writer that does not exist for image sequences.

---

## Informational — the concurrency annotations and their stated reasons

Checked against the macOS 26 SDK headers (`grep NS_SWIFT_SENDABLE`): `MTLDevice`, `MTLCommandQueue`, `MTLCommandBuffer`, `MTLRenderPipelineState`, `MTLDepthStencilState` are `NS_SWIFT_SENDABLE`; `MTLBuffer` and `MTLTexture` are not.

- `CompiledPipeline: @unchecked Sendable` (`ShaderCompiler.swift:7`) — the stated reason ("pipeline state is thread-safe") is true, and with this SDK the annotation is not even needed: every stored property is `Sendable`. Harmless.
- `MeshResources: Sendable` (checked) with `Buffers: @unchecked Sendable` (`MeshResources.swift:10-17`) — holds: buffers are written once under the `Mutex` and never mutated.
- `ExportSession.program: nonisolated(unsafe)` (`ExportSession.swift:22`) and the caller's local (`EditorModel+Recording.swift:89`) — holds: `TextureStore` only ever creates new `MTLTexture` objects (`evict`/`evictAll` drop references; `replace(region:)` is used once, on the placeholder, in `init`), so a texture captured by a running export is never written while the GPU reads it.
- `VideoSink: @unchecked Sendable` — holds: every access to `writer/input/adaptor/frameRate` is under `queue.sync`; `finishWriting()` is awaited on a local reference handed out under the queue.
- `FrameRenderer.encode` nonisolated — fine; it touches nothing shared (the `MeshResources` cache is mutex-guarded).
- One gap, not a race: `ExportSession` never checks `uniforms.layout == program.pipeline.shader.layout`, the guard `ShaderRenderer.draw` applies every frame (`ShaderRenderer.swift:31`). A mismatch is unreachable from today's `EditorModel` (program and uniforms are published in one synchronous block), but the session would render with the shader reading past the uniform buffer. Add a `precondition`/throw in `init`.

---

## What I checked and found clean

- **Uniform ring vs GPU completion** (`ShaderRenderer.swift:15, 67-75`; `UniformRing.swift`): semaphore of 3 and 3 buffers, `next()` called only after `wait()`, `signal()` on the command buffer's completion and on every early return after `wait()`; the 4th frame reuses exactly the buffer of the frame it waited for. Replacing the ring on a layout-size change is safe — in-flight command buffers retain the old `MTLBuffer`s.
- **Export resource reuse** (`ExportSession.swift:112-136`): single uniform buffer and single readback buffer are safe because `waitUntilCompleted` precedes the next `encode`, and the bytes are copied out before the next commit. `readback` is `.storageModeShared`, so no `synchronize` is needed; blit `destinationBytesPerRow = width*4` is a multiple of the pixel size; `CVPixelBuffer` row padding is handled with a per-row `memcpy`.
- **Frame counts and timestamps**: `Timeline.frameCount = round(duration*fps)` is used identically by the clock (`step`/`seek`), the scrubber, and the export loop; frame k is `k/fps` in both `TimelineClock.time` and `ExportSession`; `CMTime(k, fps)` is exact; the 12-frame test's 0.2 s confirms the multi-frame duration. No off-by-one.
- **Snapshot time**: `preview.clock.time` is `frame/fps` of the frame the renderer last drew — matches what is on screen.
- **Pass shape vs pipeline**: the offscreen pass (`bgra8Unorm` + `depth32Float`, `.dontCare` store) matches `pipelineDescriptor`; the `.realityKit` branch sets depth state, cull mode, front facing and both camera bindings identically in both front ends because there is one `encode`.
- **Struct layouts**: `CameraUniforms` 256 bytes both sides (3×64 + 48 + 16); `MeshVertex` 80 bytes both sides; camera bound with `setVertexBytes` (256 B < 4 KiB limit) at index 1 in both stages; uniforms at buffer 0 (fragment) / 2 (mesh vertex) match the generated signatures.
- **Alpha and byte order**: straight alpha, `byteOrder32Little | alphaFirst` = BGRA in memory; blending is off so fragment alpha is stored straight; the PNG test checks all four channels.
- **Cancellation and error paths**: `Task.isCancelled` at the top of every frame; `Task.sleep` in `VideoSink.write` throws `CancellationError`, which the session turns into `abandon()` + rethrow and the caller maps to `.cancelled`; scratch is removed on every exit of `record`; `abandon` on a `.failed` writer is safe (probe); `ImageSequenceSink.abandon` only ever removes a scratch subdirectory. No leaked files or Metal objects on any path.
- **`VideoSink.write` poll**: reads `writer.status` under the queue so a stopped writer throws instead of spinning (test covers it); 2 ms sleep is fine for offline writing.
- **`ShaderCompiler`**: LRU keyed by `(source, fastMath)` with a fixed pixel format; reentrancy during `await makeLibrary` can at worst compile the same source twice and keep the second (no corruption); `lazy var depthState` inside the actor is serialised.
- **Wall-clock bookkeeping**: pause folds `now - started` into `pausedElapsed` once; scrub/retarget/reset rebase it; mode switches clear `playStartedAt`; no jump on resume. Matches spec §26.3 and the handoff's live measurements.
- **Texture sampling colour**: `.SRGB: false` on load, non-sRGB drawable and export target — the pipeline is consistently "raw bytes"; item 3 is about how those bytes are *displayed*, not a mismatch inside the render path.
