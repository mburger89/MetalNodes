# MetalNodesUI Editor layer — deep review (post-M10)

Scope: `MetalNodesKit/Sources/MetalNodesUI/Editor/*`, the app target (`MetalNodes/*.swift`), and the Render/Core contracts they lean on (`PreviewState`, `ShaderRenderer`, `ExportSession`, `FrameSink`, `VideoSink`, `Timeline`, `ShaderCompiler`, `DocumentBridge`). Every file in the Editor directory and the app target was read in full; the M10 diff was read in full. Read-only; nothing was built or changed. Paths below are relative to `/Users/maxburger/Developer/MetalNodes/MetalNodesKit/Sources/` unless they start with `MetalNodes/` (the app target).

Confidence key: **confirmed** = follows unambiguously from the code as written; **plausible** = the mechanism is in the code but the user-visible outcome depends on platform behaviour I could not drive live; **unconfirmed** = a suspicion that reading alone cannot settle.

Counts: critical 0 · high 1 · medium 6 · low 12.

---

## 1. `record()` silently records a stale program — the last-good pipeline, not the graph on screen

- **Severity:** high · **Category:** bug · **Confidence:** confirmed (by reading; no test covers it — `aGraphThatStoppedGeneratingIsRefusedEvenWithALiveProgram` covers the *generation* failure, not the *Metal compile* failure)
- **Where:** `MetalNodesUI/Editor/EditorModel+Recording.swift:81-95`; contract in `MetalNodesUI/Editor/EditorModel.swift:669-691` (compile failure keeps the last-good pipeline) and `MetalNodesCore/Export/ShaderExport.swift:11-13` (`exportFiles()` only runs `ShaderGenerator.generate`, never the Metal compiler).

**What happens.** The gate is `guard (try? exportFiles()) != nil, preview.program != nil`. `exportFiles()` proves the graph *generates*; `preview.program` is whatever pipeline last *compiled*. The two diverge exactly when generation succeeds and Metal compilation fails (`compileNow`'s `.failure` branch leaves `preview.program` untouched, by design, spec §19.1). With no viewer set, `record()` then takes the `if viewState.viewer == nil, let live = preview.program` branch and records `live` — the program from *before* the failing edit — and returns `.saved`.

**Repro.**
1. Working Fragment document (preview draws it).
2. Edit ▸ New Custom Code Node; set its body to `out = nosuch(in_a);`; wire it into Fragment Output. Generation succeeds (codegen does not know MSL functions), Metal compile fails: red diagnostics, preview keeps drawing the old program.
3. File ▸ Export Video… ▸ Record. Result: an `.mp4` of the *previous* shader, no error, no warning. Same for Snapshot PNG and Image Sequence.

A second variant of the same gap: the pending-compile window. `record()` never awaits `awaitIdle()`. Open a large RealityKit document (Metal compile takes a second or more), immediately File ▸ Snapshot PNG… ▸ Record: `preview.program == nil` → the user gets "The graph has errors; fix them before recording." on a graph with none. Or, after a topology edit whose compile is still in flight, the *previous* pipeline is recorded.

**Fix.** Make the recording independent of the live preview's state. Either

```swift
// EditorModel+Recording.record(...)
await awaitIdle()
guard (try? exportFiles()) != nil else { return .failed("The graph has errors; fix them before recording.") }
guard preview.lastError == nil, !diagnostics.contains(where: { $0.severity == .error }) else {
    return .failed("The shader does not compile; fix the errors before recording.")
}
```

or, simpler and removes the two-branch divergence entirely: always generate the document's program (viewer nil) and run it through `compiler.compile` — the LRU cache makes that a hit when it *is* the live program, and a genuine compile when it is not, so the recorded pipeline is by construction the document's current one. Then compare `pipeline.shader.source` against nothing; just use it.

---

## 2. A recording that fails before its last frame dismisses the sheet and raises the error alert in the same update — the alert is likely dropped

- **Severity:** medium · **Category:** bug · **Confidence:** plausible (the mechanism is exactly the one the code's own `RecordingPhase` comment documents as "SwiftUI drops the second"; not driven live)
- **Where:** `MetalNodesUI/Editor/EditorView.swift:81-93` (`startRecording`), the failure returns in `EditorModel+Recording.swift:81-83, 102, 105, 148, 164`.

**What happens.** `startRecording` sets `recordingPhase = .progress` (sheet content swaps) and spawns the task. On the next main-actor turn `record()` returns `.failed(...)` for any early failure — graph errors, viewer-compile failure, `ExportSession.init` throwing (`sizeUnsupported`, `noDevice`), `sink.begin` throwing (H.264 encoder refusing a 16384-wide video, writer errors) — and lines 90-92 then run `recordingPhase = nil` and `exportError = message` **synchronously in the same run**. That is one SwiftUI transaction that dismisses a `.sheet` and presents an `.alert`. The file's own comment on `RecordingPhase` (lines 330-337) says why this is unsafe: "dismissing one and raising the other in the same update lets SwiftUI drop the second". The only failure path that is safe is the destination's own `.failed` (line 166 in `record`), because the progress callback took the sheet down one whole modal panel earlier.

**Repro.** Delete the Fragment Output. File ▸ Export Video… ▸ Record. Expected: "Export failed — The graph has errors…". Likely observed (especially on iPad, where UIKit refuses to present over an in-flight dismissal): the sheet flips to "Preparing…" and vanishes; nothing else happens.

**Fix.** Do not present two things. Carry the error inside the one sheet the flow already owns:

```swift
private enum RecordingPhase: Identifiable {
    case size(RecordingKind), progress, failed(String)
    var id: Int { 0 }
}
// in the task:
switch outcome {
case .failed(let message): recordingPhase = .failed(message)   // same sheet, OK button sets nil
default: recordingPhase = nil
}
```

or, if the shared alert must stay, defer it past the dismissal: `recordingPhase = nil; await Task.yield(); try? await Task.sleep(for: .milliseconds(400)); exportError = message` — uglier and timing-based, hence the first option.

---

## 3. A recording is never cancelled when its window goes away; a save panel appears after the document is closed

- **Severity:** medium · **Category:** bug · **Confidence:** confirmed (no cancellation path exists: `recordingTask` is only cancelled by the progress sheet's button, `EditorView.swift:63`, and there is no `.onDisappear`/`.task` tied to the view or the model)
- **Where:** `MetalNodesUI/Editor/EditorView.swift:77-94`; `EditorModel.swift:70` (`@ObservationIgnored public var recordingTask`).

**Repro.** Set Duration to 600 s at 60 fps (36 000 frames — legal, the bound is 3600). File ▸ Export Video… ▸ Record. While it runs, ⌘W (save when asked). The window closes; the task keeps the `EditorModel`, the `MTLDevice` and the session alive and keeps rendering on the GPU for minutes. When it finishes, `RecordingPanelMac.placeFile` runs `NSSavePanel.runModal()` with no owning window — a save panel pops up out of nowhere for a document that is no longer open; on completion `recordingPhase`/`exportError` are written into dead `@State`. On iPad the equivalent is a `fileExporter` bound to a presenter whose host view is gone: `presenter.request()` suspends forever, the task and the model leak for the app's lifetime.

**Fix.** Own the task's lifetime with the view: `.onDisappear { model.recordingTask?.cancel() }` on the editor root (or `.task(id:)` for the recording so SwiftUI cancels it). Also cancel from `reload(package:)` — a File ▸ Revert To Saved mid-recording currently records the pre-revert program and then places it.

---

## 4. Duration and preview-size drafts are discarded on focus loss and left visibly out of sync with the document

- **Severity:** medium · **Category:** bug · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/InspectorView.swift:241-245` (Duration), `:218-228` (W/H), `:465-474` (`commitDuration`). The M10 handoff (§17.3) states the Duration field "commits once on Return *or focus loss*" — the code has only `.onSubmit`; there is no `@FocusState`, no `.onChange(of: focus)`, no `.onDisappear`, unlike the export-name field at `:291-295`, which has all of that.

**Repro.** Click Duration, type `2.5`, click on the canvas (or on the frame-rate picker). The field still reads `2.5`; the caption below it still says "240 frames per loop"; `document.settings.timeline.duration` is still `4.0`; File ▸ Export Video… records 4 s. The draft is only reset when the document's duration changes for another reason or the pane re-appears, so the lie persists across the whole session. Identical for W/H (pre-M10). A user who then presses Record in the size sheet sees "240 frames — 4.0 s at 60 fps" and may not notice the mismatch.

**Fix.** Mirror the export-name field: `@FocusState private var durationFocused: Bool`, `.focused($durationFocused)`, `.onChange(of: durationFocused) { _, f in if !f { commitDuration() } }`, and `.onDisappear { commitDuration() }` — or, at minimum, reset the draft on focus loss so the field never shows a value the document does not hold. Same treatment for `widthDraft`/`heightDraft`.

---

## 5. The canvas's "defensive reset" ends a transaction that a focused text field is legitimately holding open

- **Severity:** medium · **Category:** bug · **Confidence:** plausible (both halves are in the code; the exact event ordering between focus loss and drag start on macOS is what decides how bad the outcome is)
- **Where:** `MetalNodesUI/Canvas/GraphCanvasView.swift:387, 473, 530, 584, 590` (`if model.isInTransaction { model.endTransaction() }`); the field that holds one open is `MetalNodesUI/Canvas/ParamControl.swift:82-86` (`onChange(of: focused)` → `onEditing?(now)`, i.e. `beginTransaction` on focus *gain*), routed through `InspectorView.swift:113, 126` and `InspectorView+Groups.swift:65` — none of which has the reset.

**What happens.** `ParamControl`'s text field (Expression formula, Custom Code sockets' defaults) opens a "Change Value" transaction the moment it gains focus and closes it on focus loss (`ParamControl.swift:70-100`). The canvas assumes any open transaction is a *stranded* one and pops one level before starting its own. `endTransaction` only decrements `transactionDepth` by one, so:

1. Select an Expression node; click into the inspector's formula field (transaction A open, depth 1).
2. Mouse-down on a node and drag. `beginNodeDrag` (`:473`) closes A (`commitUndo` registers nothing if the draft is uncommitted) and opens "Move" (depth 1, snapshot S).
3. The field's focus loss now fires (canvas took focus): `commitDraft()` → `apply(.setParam)` lands *inside the Move transaction*, then `onEditing?(false)` → `endTransaction()` → depth 0 → **"Move" is committed now**, with the formula edit inside it.
4. Every subsequent drag frame `apply(.moveNodes)` runs with no transaction: one "Move" undo step **per frame** (`EditorModel.apply` line 349-351). `endNodeDrag`'s `endTransaction()` then hits `guard transactionDepth > 0` and does nothing.

Outcome: ⌘Z steps back through dozens of one-pixel moves, and the formula edit is labelled "Undo Move". If the focus-loss lands first instead, the outcome is benign — which is why this is plausible rather than confirmed.

Secondary effect (confirmed): while any `ParamControl` text field is focused, every unrelated edit — the inspector's Loop toggle, Time picker, a "Live" checkbox, `PlaybackControls`' Loop switch, none of which takes keyboard focus on macOS — is absorbed into the field's open transaction (`apply` line 346-347) and registered under "Change Value" when the field eventually loses focus, or not at all if the field is torn down by a selection change before `onDisappear` runs.

**Fix.** Stop guessing. Give transactions an owner token: `beginTransaction(_ name:) -> TransactionToken` and `endTransaction(_ token)`, so a stale one can be identified and a foreign one is never closed; or, cheaper, make the text field not hold a transaction across focus at all — open it in `commitDraft()` around the single `onChange` call (begin/apply/end), which is what it needs the transaction for. Then the defensive resets can go.

---

## 6. iPad: `FileWrapper(url:options: .immediate)` reads the whole recording into memory before the exporter runs

- **Severity:** medium (iPad only) · **Category:** perf/robustness · **Confidence:** confirmed (already listed as M11 item 2 in the handoff; recorded here because it is a jetsam risk, not a nicety)
- **Where:** `MetalNodesUI/Editor/RecordingDestinationPad.swift:25`.

A 240-frame 1080p image sequence is ~2 GB of PNG; a 4K sequence more. `.immediate` materialises all of it as `Data` in the wrapper *and* the exporter then writes it out — two copies at peak. The comment justifies it with "the recording removes [the scratch] as soon as this call returns", but `record()` removes the scratch *after* `await destination.place(...)` returns (`EditorModel+Recording.swift:166-167`), and `place` does not return until `fileExporter` has completed or cancelled — so the scratch is still on disk for the whole write. A lazy `FileWrapper(url: temporary)` (or the handoff's own suggestion, `fileExporter(item:)` with a `Transferable` URL) is safe today.

---

## 7. The size sheet's bound (16384) is Metal's texture limit, not a memory bound

- **Severity:** medium · **Category:** bug/robustness · **Confidence:** confirmed for the allocation sizes; the device's reaction (refusal vs. jetsam) is platform-dependent
- **Where:** `MetalNodesUI/Editor/RecordingSheet.swift:21-23`; `MetalNodesRender/Recording/ExportSession.swift:39, 49-53, 73-75, 136`.

A 16384 × 16384 snapshot is accepted by the sheet. `ExportSession.init` then allocates a 1 GB colour target, a 1 GB depth target (depth32Float — allocated even for a 2D program), a 1 GB shared readback buffer; `renderFrame` copies the readback into a 1 GB `[UInt8]`, `ImageSequenceSink.cgImage` copies that into a 1 GB `Data`, and `ImageIO` encodes from it. Peak is ~4-5 GB transient for one PNG. On an iPad that is a kill; on a Mac it is a long beach-ball with a 64 KB progress bar. The preview-size fields cap at 8192 (`InspectorView.swift:447-448`); the recording sheet should cap at the same or, better, at a pixel budget derived from `device.recommendedMaxWorkingSetSize`, and `ExportSession.init` should refuse when `stride * h > device.maxBufferLength`. H.264 hardware encoders also reject widths above 4096/8192 — that surfaces as `writerFailed` only after the sheet is gone (see finding 2 for why the user may never see it).

---

## 8. `syncClock()` re-bases the wall clock on every `.setSettings` and every undo, whether or not the timeline moved

- **Severity:** low · **Category:** bug · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/EditorModel.swift:495, 523`; `EditorModel+Recording.swift:15-25`.

`syncClock` unconditionally calls `rebaseWallClock`, which sets `pausedElapsed = frame / frameRate` and clears `playStartedAt`. `.setSettings` is also the vehicle for image import (`EditorModel+Assets.swift:70`), asset removal/relink, export-name commit, the fast-math and lighting toggles, `toggleLiveParameter`, and every `.restore` (undo/redo of anything). Effects in `.wallClock` mode: (a) sub-frame phase is dropped each time (up to 1/frameRate of drift per unrelated settings write — visible as a stutter when dropping an image onto the canvas mid-playback); (b) with `loops` off and time past the end, the readout at `EditorView.swift:299-300` snaps from e.g. `37.20 s` back to `4.00 s` when the user renames the export or undoes a node move, because `elapsedSeconds` is rebuilt from the pinned frame. Fix: in `perform(.setSettings)` and `.restore`, call `syncClock()` only when `settings.timeline != old.timeline || settings.timeMode != old.timeMode`.

---

## 9. Wall-clock, non-looping: Play/Pause at the end does nothing, and the state machine never reports "stopped"

- **Severity:** low · **Category:** bug · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/EditorModel+Recording.swift:37-43`; `MetalNodesRender/ShaderRenderer.swift:44-53`; `MetalNodesCore/Timeline.swift:63-71`.

`seek(elapsed:)` pins `frame` at the end but never clears `isPlaying`, so the button reads "Pause" while nothing moves, and `pausedElapsed` keeps accumulating past the duration. `togglePlayback`'s restart-at-end special case is `.fixedRate`-only (its comment says the wall clock "re-seeks from `pausedElapsed`" — but `pausedElapsed` is past the end, so the re-seek pins again). Repro: Loop off, wall clock, wait 5 s on a 4 s timeline → press Pause, press Play: frame stays 240/240. The two modes should agree: either `seek` sets `isPlaying = false` at the end (and `togglePlayback` restarts from 0 for both modes), or the readout should not count past the end.

---

## 10. `compileNow`'s "same program as last time" shortcut leaves stale missing-texture warnings when that last compile failed

- **Severity:** low · **Category:** bug · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/EditorModel.swift:650-663`; the caller that relies on it, `EditorModel+Assets.swift:100-103` (`replaceAssetBytes` → `scheduleCompile()` "so the missing warning goes away").

In the early-return branch, `diagnostics = missing` is only assigned under `if last.succeeded`. When the last settled compile of this exact source *failed*, `diagnostics` is left untouched — including the "Texture “x” is missing" warning that `replaceAssetBytes` just made obsolete (it removed the id from `missingTextures`). Repro: document whose current source fails Metal compile and also references a texture whose bytes are missing; Relink… the texture; the missing warning stays until the source changes. Fix: keep the mapped compile errors in `lastCompiled` and rebuild `diagnostics = errors + missing` in both branches.

---

## 11. Every document mutation invalidates the whole-graph shape cache, including per-frame drags and per-tick slider changes

- **Severity:** low · **Category:** perf · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/EditorModel.swift:528` (`shapesVersion += 1` after every `perform`); consumers `EditorModel.swift:273-283`; the drag at `MetalNodesUI/Canvas/GraphCanvasView.swift:501` applies `.moveNodes` per drag frame.

`.moveNodes`, `.moveComments`, `.resizeComment`, `.setSettings` and a uniformable `.setParam` cannot change any `NodeShape`, yet each bumps the version, so the next layout pass rebuilds every shape in the active graph (`ShaderDocument.shape(of:in:registry:)` — for Expression nodes that re-tokenises the formula, `ExpressionNode.swift:71-80`). At 60 Hz during a node drag or a slider drag that is a full O(N) rebuild per frame. Not measurable on the sample graphs; it will be on a few-hundred-node RealityKit graph with many Expressions. Fix: bump only for changes whose `changeClass == .topology` plus `.setTitle` (Expression shapes carry `customTitle`) and non-uniformable `.setParam`; `.restore` and the group operations already fall under topology.

---

## 12. Changing the frame rate keeps the frame *index*, so the time jumps

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed (acknowledged in `syncClock`'s comment)
- **Where:** `MetalNodesCore/Timeline.swift:85-89` (`retarget`), `EditorModel+Recording.swift:10-18`.

At frame 100 of 240 (t = 1.67 s, 60 fps), switching the picker to 24 fps clamps to frame 95 of 96 → t = 3.96 s: playback leaps to the end and, with Loop off in fixed rate, stops on the very next draw. Preserving *time* is what a user changing a frame rate expects: `frame = min(Int((time * newRate).rounded()), newCount - 1)` inside `retarget`, computed before `self.timeline` is replaced.

---

## 13. Escape does not cancel the size sheet on macOS; Return records

- **Severity:** low · **Category:** improvement · **Confidence:** plausible (SwiftUI on macOS only binds Esc to `role: .cancel` buttons inside alerts/confirmation dialogs, not sheets)
- **Where:** `MetalNodesUI/Editor/RecordingSheet.swift:55-58`.

`Button("Record").keyboardShortcut(.defaultAction)` is there; the Cancel button has no `.keyboardShortcut(.cancelAction)`. Add it, and the same on `RecordingProgressSheet` (`:93`) so the keyboard can cancel a running recording — today the only way is the mouse.

---

## 14. Recording menu items stay enabled while a recording runs; the second request is silently dropped

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/EditorCommands.swift:68-71`, `EditorViewPad.swift:143-145`, `EditorView.swift:48-51` (the guard that drops it).

`.disabled(model == nil)` should be `.disabled(model == nil || model?.recordingTask != nil)`. `recordingTask` is `@ObservationIgnored`, so make the gate an observed `isRecording` flag set alongside it (the command tree re-evaluates on observed reads only).

---

## 15. Bare-key playback shortcuts stay armed while a *different* key window has text focus

- **Severity:** low · **Category:** bug · **Confidence:** unconfirmed (mechanism argued; not driven live)
- **Where:** `MetalNodesUI/Editor/EditorCommands.swift:197-208` (`p`, `,`, `.`, ⌘0) and the pre-existing `f`/Home at `:171-176`; gate source `MetalNodesUI/Canvas/GraphCanvasView.swift:185-188`.

`canvasHasFocus` is derived from the canvas's `@FocusState`, which tracks the first responder of the *editor window*. A SwiftUI `.sheet` on macOS is a separate `NSWindow`; presenting it does not change the parent's first responder, so `canvasHasFocus` stays `true` while the recording size sheet is up. AppKit offers unmodified key equivalents to the main menu before the key window's field editor sees them (that is precisely why M9 gates these items). So, if the canvas was focused when File ▸ Snapshot PNG… was chosen, typing `,` or `.` in the W/H fields steps the preview clock — and the snapshot is taken at `preview.clock.time` (`EditorModel+Recording.swift:139`), so the accidental keystroke changes which frame is recorded. Verify live; if real, clear `canvasHasFocus` while `recordingPhase != nil` (the sheet knows), or gate the playback items additionally on `recordingPhase == nil` via an observed model flag.

---

## 16. `ExportSession.renderFrame` blocks a cooperative-pool thread per frame; cancellation is only checked between frames

- **Severity:** low · **Category:** perf · **Confidence:** confirmed
- **Where:** `MetalNodesRender/Recording/ExportSession.swift:134` (`cmd.waitUntilCompleted()` inside the actor), `:96` (the only `Task.isCancelled` check).

For a heavy raymarcher at 4K a frame can take hundreds of ms; the actor's executor thread sleeps in the kernel for all of it, and a Cancel pressed mid-frame is honoured only at the next frame boundary. `withCheckedContinuation` around `cmd.addCompletedHandler` keeps the pool free, and lets the cancel land while the GPU runs. Not user-visible on the sample shaders.

---

## 17. `RecordingPanelMac` duplicates `ExportPanelMac`'s replace-confirmation and install logic

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/RecordingPanelMac.swift:32-79` vs `MetalNodesUI/Editor/ExportPanelMac.swift:40-77`.

Two `confirmReplace` alerts with different wording and two open-panel configurations that must stay in step (both exist because of the same sandbox rule — a save panel grants one URL, an open panel grants a folder). One `MacPanels` helper (`chooseFolder(title:message:)`, `chooseFile(name:types:)`, `confirmReplace(names:)`, `install(temporary, at:)`) would also let `ExportPanelMac.runFolder` use the atomic `replaceItemAt` path instead of `write(atomically:)` twice.

---

## 18. Model → file mirroring compares whole documents three to four times per mutation

- **Severity:** low · **Category:** perf · **Confidence:** confirmed
- **Where:** `MetalNodes/DocumentHostView.swift:36-40`; `MetalNodesUI/Editor/DocumentBridge.swift:38, 50`.

`.onChange(of: bridge.model.document)` diffs the full `ShaderDocument` on every body re-evaluation; `mirror` compares again; the resulting `file.package` write fires `.onChange(of: file.package)` (full package equality including texture `Data`), and `bridge.apply` compares document, view state and textures once more. Per drag frame. Cheap on today's graphs; the cleaner shape is to key the `onChange` on a cheap `documentVersion` counter (as `texturesVersion` already does for bytes) and keep the single comparison inside `mirror`.

---

## 19. `setTimeline`'s doc comment names the wrong undo step

- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `MetalNodesUI/Editor/EditorModel+Recording.swift:56` says "undoable as 'Change Value'"; the step is `.setSettings`, whose `undoName` is "Change Settings" (`DocumentChange.swift:119`). The Edit menu reads "Undo Change Settings" for a duration edit, a loop toggle, and a frame-rate change alike — a dedicated `.setTimeline(Timeline)` change (or a `name` on `.setSettings`) would let the menu say "Undo Change Duration".

---

## What I checked and found clean

- **Undo core** (`EditorModel+Undo.swift`): snapshot-per-transaction, redo registered from inside the undo handler, `commitUndo`'s `before != document` guard, nested begin/end/cancel depth handling, `.restore` bypassing registration, the unnamed-group skip in `undo()/redo()`, `adoptUndoManager` refusing a non-empty stack, `reload` dropping the stack and open transaction. All consistent with the tests.
- **Timeline ↔ clock sync on undo/redo/reload**: `.restore` and `reload(package:)` both call `syncClock()`; `retarget` clamps; the tests in `EditorRecordingTests` cover the interesting transitions. (Finding 8 is about *over*-syncing, not a miss.)
- **DocumentBridge / DocumentHostView**: undo registration disabled around the mirror; `.viewState`/`.textures`-only writes mark the platform document; a `.document` write rides the model's own step; external package changes reseed via `reload`. `PlatformDocument.markChanged` fallbacks are sound for the cases that matter.
- **Compile pipeline**: `scheduleCount`/`awaitIdle` loop, debounce cancellation, per-model generation guard against a shared compiler, `lastCompiled` keyed on source + texture slots + fastMath, `.superseded` handled, texture bindings republished with the pipeline as one value.
- **Recording data path**: scratch-directory-then-move design is the right answer to the sandbox (save-panel single-URL grant, open-panel folder grant); scratch removed on every exit path including `ExportSession.init` failure; `sink.abandon()` on cancel and on error; `VideoSink` serialises writer access through its queue and exits its ready-poll when the writer stops; `CancellationError` and `RecordingError.cancelled` both map to `.cancelled`; progress is awaited per frame so the last report is ordered before `finish()`.
- **Sheet design**: one `.sheet(item:)` with a constant id for size → progress avoids the two-modifier drop; `.interactiveDismissDisabled()` on the progress sheet; `recordingTask` as the re-entrancy interlock; the progress callback dismisses before the destination presents. (Finding 2 is the one gap in this design.)
- **iPad presenters**: `PickerPresenter` resolves once; `RecordingDestinationPadHost` mirrors `ExporterPadHost` (`isPresented` only while a document is pending; setter never resolves; `onCancellation` covers the dismissal path); `padHosts` attaches each host exactly once at the window root.
- **Keyboard**: Play/Pause deliberately off bare Space (canvas pan latch); all new bare keys gated on `canvasHasFocus` like the M9 set; `EditorCommands` reads nothing off `preview.clock`, so the command tree is not invalidated at refresh rate.
- **Observation hygiene**: `PlaybackControls` is the only view reading `preview.clock`, isolated as its own `View`; `ShaderRenderer`'s fixed-rate branch guards its writes while paused; `recordingTask`, `thumbnailCache`, `shapesCache*` are `@ObservationIgnored` for the right reasons; `EditorViewPad`'s bindings write only on change.
- **Clipboard/insert refusal paths**: `insert` verifies the ids actually landed; `addNode`/`addInstance` explain a refusal instead of returning a phantom id; recursion and terminal-into-definition refusals happen before the transaction opens.
- **Prune order after removal** (`pruneAfterRemoval`): editing stack → selection → comment selection → viewer → live parameters, with the overlapping-access snapshot in `pruneLiveParameters`.
- **Asset import**: manifest through `.setSettings` (undoable), bytes outside the snapshot, thumbnail cache invalidated on byte change, `evict`/`evictAll` before rebinds, security-scoped reads claimed and released.
- **App target**: `LaunchFixture` nonisolated for `DocumentGroup(newDocument:)`; `ShaderFileDocument` rewraps `PackageError` so the reason survives NSDocument's alert; per-window `EditorServices` kept in `@State` so iPad presenters are stable.
