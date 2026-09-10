# Canvas layer review — `MetalNodesUI/Canvas`, `Palette`, `Theme`

Scope read in full: every file under `Sources/MetalNodesUI/Canvas`, `Palette`, `Theme`; the model side the canvas calls into (`EditorModel.swift` apply/perform/shapes/activePath, `+Undo`, `+Selection`, `+Comments`, `+Groups`, `+Clipboard`), `EditorCommands.swift`, both hosts (`EditorView`, `EditorViewPad`), `MetalNodesCore` `EditorViewState`, `ShaderDocument.node(_:)`, `NodeShape`, and the canvas-related test suites. Paths below are relative to `/Users/maxburger/Developer/MetalNodes/MetalNodesKit/Sources/MetalNodesUI/` unless stated.

Severity counts: **critical 0 · high 5 · medium 9 · low 8** (22 findings). Nothing here was modified; no build was needed to confirm what is marked confirmed — each is traced in the code.

---

## HIGH

### H1. Scroll-wheel pan/zoom writes `viewState.cameras` on every wheel tick, invalidating every `viewState` reader in the app
- **Severity:** high · **Category:** perf · **Confidence:** confirmed
- **Where:** `Canvas/GraphCanvasView.swift:100-107` (`ScrollWheelCatcher { … model.viewState.cameras[model.activePath] = transform.camera }`)
- **Cost:** `viewState` is a single stored struct on the `@Observable` model, so a write to `cameras[…]` invalidates *every* view that reads any `viewState` member: `EditorCommands` (`selection`, `showsMinimap` in `.disabled`/`Toggle`), `InspectorView`, `BreadcrumbBar`, `EditorViewPad` (`showsInspector`), `CodePanel`, `MinimapView`, and the canvas itself (`selection`, `selectedComments`, `canvasMode`, `activePath`). The scroll wheel is the primary macOS pan input and fires at 60–120 events/s with momentum, so a two-finger flick re-evaluates the whole editor UI, including the menu command tree, dozens of times. The drag-gesture and magnify paths deliberately write the camera only in `onEnded` (`:720`, `:808`); the touch path writes only on `endPan`/`endZoom`. The wheel path is the one outlier and the most-used.
- **Fix:** keep `transform` (`@State`) as the live camera and persist lazily: write `cameras[…]` on the scroll event's `.ended` momentum phase (`NSEvent.momentumPhase`/`phase` are available in `CatcherView.handle`) or on a short debounce/`Task` after the last tick; or move `cameras` out of `viewState` into its own `@ObservationIgnored` dictionary that is folded into `package` on save. Either removes the per-tick invalidation.

### H2. `hoverLocation` is `@State`, so every pointer move over the canvas re-evaluates the entire canvas body (all visible `NodeView`s)
- **Severity:** high · **Category:** perf · **Confidence:** confirmed
- **Where:** `Canvas/GraphCanvasView.swift:54`, `:189-194` (`.onContinuousHover { … hoverLocation = p }`)
- **Cost:** a `@State` write always invalidates the owning view's body. `GraphCanvasView.body` builds `content` inline (`:347-404`), which constructs a fresh `NodeView` value with nine closures per visible node; views holding closures are never considered equal by SwiftUI, so each NodeView body (with its `ParamControl`s, `TextField`s, `Slider`s, `ColorPicker`, socket `GeometryReader`s) re-runs. Net effect: moving the mouse across the canvas at rest runs a full canvas layout pass per pointer event. `hoverLocation` is only *read* lazily — by ⇧A (`:197`), the context menu (`:131`), and Paste (`:257`) — none of which needs a body re-run when it changes.
- **Fix:** store the hover point somewhere that is not observed: a `final class PointBox { var p: CGPoint }` held in `@State` (mutating a field of a reference type does not invalidate), or read `NSEvent.mouseLocation` converted into the viewport at ⇧A/paste time (macOS), keeping `onContinuousHover` only for the `.ended` reset. Same treatment is worth applying to `anchors` (H3) so the second pass per frame does not fan out through closures.

### H3. Every drag frame invalidates the shape cache; inside a definition every shape lookup also sorts all definitions by `uuidString`
- **Severity:** high · **Category:** perf · **Confidence:** confirmed
- **Where:** `Editor/EditorModel.swift:528` (`shapesVersion += 1` after *every* `perform`, `.moveNodes` included), `:259` (`activePath` → `EditorViewState.activePath(in:)` → `ShaderDocument.node(_:)`), `MetalNodesCore/ShaderDocument.swift:298-304` (`definitions.values.sorted { $0.id.raw.uuidString < … }` on every miss of `root`).
- **Cost:** a node drag applies `.moveNodes` per mouse event (`GraphCanvasView.swift:501`). `perform` bumps `shapesVersion` unconditionally, so the next `shapes` read (`:270-283`) rebuilds every `NodeShape` of the active graph — for an Expression node that means `MSLScanner.identifiers(in:)` over the formula (`ExpressionNode.shape(for:)`) per node per frame. Worse, `activePath` is read by `graph`, `shapes`, `shape(of:)`, `isEditingCode`, `apply` and `perform`; when the editor is inside a definition, `ShaderDocument.node(_:)` misses `root` and then **sorts every definition, allocating a `uuidString` per comparison, on every call**. `NodeGeometry.visibleNodes`/`nodes(in:intersecting:)`/`bounds`/`socketAnchor` call the `shapes` closure once per node, so a body pass inside a definition costs O(n · D log D) string allocations before it has drawn anything. A document with ~50 "My Functions" definitions and a 100-node group body will feel this on every hover (H2) and every drag frame.
- **Fix:** (a) in `perform`, bump `shapesVersion` only when the change can alter a shape — `.setParam` with a non-uniformable value, topology, definitions, `.restore`; the `.cosmetic` class (moves, resizes, comments, title) never does; (b) cache `activePath` per `viewState`/`document` version, or make `ShaderDocument.node(_:)` O(1) with a document-level `[NodeID: GraphPath]` index maintained by the graph setter, or at least drop the sort (iterate `definitions` unordered — ids are unique document-wide, so order cannot change the answer).

### H4. Zooming across the LOD threshold mid-wire-drag strands `pendingWire` and its transaction (macOS)
- **Severity:** high · **Category:** bug · **Confidence:** confirmed (structural)
- **Where:** `Canvas/NodeView.swift:67-85` (`if !compact { … inputRow/outputRow … }`), `:277-279`/`:306-308` (`.gesture(socketDrag(…))` lives on the `SocketView` inside those rows), `Canvas/GraphCanvasView.swift:359` (`compact = transform.zoom < Self.lodZoom`), `:100-107` (⌘-wheel zoom is live during any drag).
- **Scenario:** at zoom 0.45, mouse-down on an output socket and start dragging a wire (`beginWire` opens "Connect" — or "Rewire" with `.disconnect` already applied, `:580-587`). While the button is still down, roll the ⌘-wheel two notches (`exp(-0.1)` each, `:797`): zoom crosses 0.4, `compact` flips, the standard body's rows are removed from the hierarchy and the `SocketView` owning the `DragGesture` is torn down. SwiftUI cancels the gesture **without `onEnded`**, so `onSocketDragEnded` → `endWire` never runs: `pendingWire` stays non-nil (the wire keeps drawing to its last point, every incompatible socket stays dimmed, the source node is pinned by `nodesInFlight`), and the transaction stays open, which makes `EditorModel.undo()` a silent no-op (`+Undo.swift:51`). The only exits are Escape (`:168-173`) or starting another socket drag; a subsequent node drag "defensively" closes the transaction (`:473`) — for a re-drag that *commits* the detachment as an undo step named "Move". The same teardown happens if the node is *culled* during the drag — that case is protected by `nodesInFlight`, but the LOD flip is not.
- **Fix:** keep the socket views mounted in compact mode (the compact header already renders `SocketView`s at 0.6 scale, `:164-170`, `:193-199` — attach `socketDrag` there too so the gesture owner survives the flip), or hoist the socket drag onto the node view like `headerDrag`, or freeze `compact` while `pendingWire != nil` (`let compact = pendingWire == nil && transform.zoom < lodZoom`) so a live drag cannot change the body's structure. Belt-and-braces: `endNodeDrag`/`beginNodeDrag`'s defensive reset should also clear `pendingWire` via `cancelTransaction`, not `endTransaction`.

### H5. Bare-key playback/zoom equivalents (`p` `,` `.` `f` Home) versus text fields hosted in another window (⇇A chooser popover, sheets)
- **Severity:** high if true · **Category:** bug · **Confidence:** unconfirmed — needs a 10-second live check
- **Where:** `Editor/EditorCommands.swift:172-208` (gated only on `model?.canvasHasFocus`), `Canvas/GraphCanvasView.swift:185-188` (the only place that clears `canvasHasFocus` is `.onChange(of: canvasFocused)`), `Palette/NodeSearchPopover.swift:20-22, 44` (a `TextField` that grabs focus inside a `.popover`).
- **Why it matters:** on macOS a menu key equivalent is matched by `NSApplication.sendEvent` *before* the key window's `keyDown:` reaches any text view — the only thing that keeps a bare `p` out of a text field is the item being disabled. Inspector/node fields are in the canvas's own window, so focusing them flips the canvas's `@FocusState` and the items go disabled — the M10 live check confirms that for the Export-name field. The ⇧A chooser is an `NSPopover` (separate window); nothing in the code clears `canvasHasFocus` when its `TextField` takes focus, and `@FocusedValue(\.editorModel)` is scene-scoped, so `model` is still resolved. If the canvas's `@FocusState` stays `true` while the popover is key (this is the part I cannot prove from source), then typing **`p`** (step, lerp, clamp, perlin, position), **`f`** (fbm, fract, float), **`,`** or **`.`** into the chooser fires Play/Pause / Zoom to Selection / frame-step and the character is swallowed. M10 tripled the exposed key set (`p , .` joined `f`/Home), and the handoff notes "the View menu showed every playback item enabled throughout" the M10 session. None of the recorded live checks typed one of these letters into the ⇧A chooser on macOS (M6's "mix" was on iPad).
- **Check:** ⇧A on the canvas, type `fp,.` — all four characters must appear in the field with no playback/zoom change.
- **Fix if it reproduces:** have `NodeSearchPopover` report focus to the canvas (an `onFocus: (Bool) -> Void` that sets `model.canvasHasFocus`), or gate the bare-key items additionally on `!(NSApp.keyWindow?.firstResponder is NSText)` (the exact test `EditorCommands.textViewIsFirstResponder` already uses for Undo), which covers popovers and sheets alike.

---

## MEDIUM

### M1. `NodeView` (and `WireLayer`, `CommentLayer`) can never be skipped by SwiftUI: nine closures per node, rebuilt each body; the anchor preference then forces a second full pass per frame
- **Severity:** medium (structural, compounds H1–H3) · **Category:** perf · **Confidence:** confirmed
- **Where:** `Canvas/GraphCanvasView.swift:370-400` (closures built inline per node per body), `:260` (`onPreferenceChange(SocketAnchorKey) { anchors = $0 }` → another `@State` write → another body), `Canvas/SocketView.swift:53-57` (one `GeometryReader` per socket), `Canvas/InteractiveRect.swift:17-19` (a second `GeometryReader` per param control on iOS).
- **Cost:** per drag frame: `.moveNodes` invalidates `document` → canvas body #1 → every visible NodeView body → socket `GeometryReader`s report → `anchors` changes → canvas body #2 → every NodeView body again. Each NodeView body evaluates `ParamControl`s whose `TextField(value:format:)`/`ColorPicker`/`Slider` are the most expensive leaf controls SwiftUI has. On a 100-node graph with ~40 visible that is ~80 NodeView bodies per frame (the handoff's "103-node drag without a stall" is at the edge; 300 visible nodes is where it stalls).
- **Fix:** give NodeView stable, comparable inputs: bundle the callbacks into a `final class NodeActions` (compared by identity) or route them through `EnvironmentValues`, keep only value fields on the view, and mark it `Equatable` (or wrap in `EquatableView`). Move `content` into a child `CanvasContent: View` whose inputs are values (`visibleNodes`, `anchors`, `pendingWire`, `selection`, `compact`) so H2's hover writes and transform changes that do not alter the visible set never reach it. Re-cull only when the visible rect drifts more than `cullMargin/2` since the last cull (hysteresis) so a pan does not recompute `visible` every tick.

### M2. `drawOrder`/`byID` allocate a `uuidString` per comparison inside every sort — culling, hit-testing, comment layers and drop resolution all pay it every pass
- **Severity:** medium · **Category:** perf · **Confidence:** confirmed
- **Where:** `Canvas/NodeGeometry.swift:163-165` (`(Int, String)` key with `uuidString`), `:157-159` (`visibleNodes` sorts all nodes per body), `Editor/EditorModel+Selection.swift:96-102` (`node(at:)` sorts *all* nodes to find one), `Canvas/CommentLayer.swift:52-62`, `Canvas/DropResolver.swift:84`, `Editor/EditorModel+Comments.swift:178-180` (`description` per comparison).
- **Cost:** n log n String allocations per canvas body (twice per frame per M1), plus per hit-test on iPad (`hit(at:)` runs `node(at:)` on every tap/drag latch). At 1 000 nodes that is ~20 000 short-lived Strings per frame just to order the ZStack.
- **Fix:** compare `node.id.raw` directly (`UUID` is `Comparable` on the deployment targets in use), or precompute the key once per node (`NodeInstance` could cache `sortKey`); `node(at:)` needs `max(by:)` over the candidates, not a full sort.

### M3. Grid dots are one `fill` per dot — up to tens of thousands of path fills per frame, redrawn on every canvas body
- **Severity:** medium · **Category:** perf · **Confidence:** confirmed (arithmetic)
- **Where:** `Canvas/GraphCanvasView.swift:450-467`
- **Cost:** spacing is `24·zoom` with an 8 pt floor, so at zoom ≤ 0.33 a 1600×1000 viewport issues 200×125 = 25 000 `ctx.fill(Path(ellipseIn:))` calls; a 5K display at that zoom is ~100 000. The `Canvas` closure captures `transform` and is re-run on every body evaluation (including H2's hover passes and every drag frame, where the grid has not changed).
- **Fix:** build one `Path` with all ellipses and fill once; better, draw a single `GraphicsContext.Shading.tiledImage`/pattern of one dot, or use `ctx.fill(Path, with: .shader(...))`. Hoist the grid into its own child view keyed only on `(pan mod spacing, spacing, size)` so it is not re-rendered when only nodes change.

### M4. Wires are drawn in a 4000×4000 `Canvas` — any wire endpoint at a negative coordinate or beyond 4000 is clipped
- **Severity:** medium · **Category:** bug · **Confidence:** plausible (depends on `Canvas` clipping, which I believe it does; 30-second live check)
- **Where:** `Canvas/GraphCanvasView.swift:75` (`contentSize = 4000`), `:95` (`content.frame(width: 4000, height: 4000, alignment: .topLeading)`), `Canvas/WireLayer.swift:55-67` (the greedy `Canvas` fills that frame).
- **Scenario:** nothing constrains node positions: open the sample, pan the canvas right by ~500 px, ⇧A-place a node at the left edge → its `position.x ≈ −400`. `NodeView`s are placed with `.offset`, so the node is drawn; the wire into it is drawn by `WireLayer`'s `Canvas`, whose bounds are (0…4000)². If `Canvas` clips to its bounds (it renders into a layer of that size), the wire disappears for `x < 0`. Same at `x > 4000` for a wide graph, which Zoom to Fit at minZoom 0.15 can show comfortably. Hit-testing (`wire(at:)`) still finds the invisible wire, so the user can select what they cannot see.
- **Check:** place a node at negative x, wire it; the wire's left part is visible or not.
- **Fix:** size the `content` frame from `model.contentBounds ∪ viewport` (with margin) and translate by its origin, or simply drop the fixed frame and let `WireLayer` be `.frame(width: bounds.width, height: bounds.height).offset(bounds.origin)` — the anchors are already in canvas space, so only the Canvas's origin needs to move.

### M5. `ColorPicker`, vector `TextField`s and `Stepper` register one undo step per tick/keystroke (no editing transaction)
- **Severity:** medium · **Category:** bug (undo UX) · **Confidence:** confirmed
- **Where:** `Canvas/ParamControl.swift:201-209` (ColorPicker), `:223-231` (`TextField(value:format:)` ×2/3), `:193-195` (Stepper); only the `Slider` (`:180`) and the text field (`:75-86`) call `onEditing`.
- **Scenario:** drag the colour wheel of a Color node's `Color` param for a second: every colour-panel tick calls `onChange(.setParam)` → `model.apply` outside any transaction → `commitUndo` per tick. ⌘Z then walks back one tick at a time (dozens of "Undo Change Value"). Typing `0.25` into a `float3` component field commits `0`, `0.2`, `0.25` as three steps (the handoff's own M10 finding about `TextField(value:format:)` committing per keystroke applies here too — it was fixed for the Duration field only). The per-keystroke commit also re-formats the field to two decimals mid-typing.
- **Fix:** open a "Change Value" transaction on the first change and close it on a short idle timer (`Task.sleep(200 ms)`) or on focus loss, as the Duration field now does with a draft string; for the vector fields adopt the same draft-string pattern.

### M6. `hit(at:)`, marquee, culling and computed anchors trust an *estimated* node height that nothing measures
- **Severity:** medium (iPad hit-testing; wires to culled nodes) · **Category:** bug · **Confidence:** unconfirmed (needs a pixel measurement of a node with an enumeration `Picker`, a `Stepper` and a `ColorPicker`)
- **Where:** `Canvas/NodeGeometry.swift:75-78`, `:101-123`; consumers `Editor/EditorModel+Selection.swift:96-102`, `Canvas/GraphCanvasView.swift:816-826` (iPad tap/drag latch), `:729`, `:890`, `Canvas/WireLayer.swift:50-52`.
- **Why:** each body row is assumed to be 16 pt of content + 6 pt spacing. A regular-size `Picker(.menu)` (`ParamControl.swift:34-40`, no `controlSize`), `Stepper` and `ColorPicker` on macOS are 20–24 pt tall. A node with two such rows is ~10–16 pt taller than its estimate: on iPad a tap on its bottom row resolves as `.empty` (clears the selection); a wire into an *off-screen* such node attaches to the wrong y (`socketAnchor` fallback); the marquee/`contentBounds` miss its bottom edge. The tests (`NodeGeometryTests.synthesizedSocketAnchorsMatchNodeViewLayout`) compare constants with constants, never a rendered frame.
- **Fix:** report each `NodeView`'s frame through a preference (exactly as `SocketAnchorKey` does) and prefer measured frames in `node(at:)`/marquee/culling when present; or pin the row controls to `controlSize(.mini/.small)` and assert the 16 pt row in a live check.

### M7. Two `.dropDestination` modifiers are stacked on the canvas and neither drop has ever been verified by automation
- **Severity:** medium · **Category:** bug · **Confidence:** unconfirmed (the handoff lists both "Finder → canvas image drop" and "palette drag-in" as never delivered by automation)
- **Where:** `Canvas/GraphCanvasView.swift:200-219`
- **Why:** each `.dropDestination(for:)` installs its own drop delegate on the same hosting view; whether the outer (`URL`) one declines a `NodeDefTransfer` payload so the inner one can accept it is not something the code can promise. If it does not, palette drag-in is dead on macOS. Both drops have only been exercised by hand, if at all.
- **Check:** drag a palette row onto the canvas; drag a PNG from Finder onto the canvas.
- **Fix if needed:** one `.dropDestination(for: DropPayload.self)` where `DropPayload: Transferable` declares both representations (`ProxyRepresentation` for `URL`, `CodableRepresentation` for `NodeDefTransfer`), or `onDrop(of: [.metalNodesNodeDef, .fileURL])` with a single delegate.

### M8. `spaceHeld` can latch on: unhandled `.repeat` phase, and no `.up` if the app deactivates while Space is down
- **Severity:** medium (a drag that pans instead of marquee-selecting until the user presses Space again) · **Category:** bug · **Confidence:** confirmed for the deactivate path; the repeat-beep is unconfirmed
- **Where:** `Canvas/GraphCanvasView.swift:162-165`, `:185-188`
- **Scenario:** hold Space, ⌘-Tab to another app (or a notification steals key), release Space there, come back: no `.up` arrived, `canvasFocused` never changed (focus is per window, not per app activation), so `spaceHeld` is still `true` and the next background drag pans. Also `phases: [.down, .up]` leaves auto-repeat `.repeat` events unhandled; they fall through the responder chain (possible system beep on macOS — not verified).
- **Fix:** include `.repeat` (treat as down); clear `spaceHeld` on `NSApplication.didResignActiveNotification` / `scenePhase != .active`; and read the modifier live instead of latching — `NSEvent.modifierFlags` cannot see Space, but `CGEventSource.keyState(.combinedSessionState, key: 49)` can, so `beginBackgroundDrag` could ask "is Space down now?" and never go stale.

### M9. Keyboard edits during a live header drag leak the drag transaction and mislabel the undo step
- **Severity:** medium-low · **Category:** bug · **Confidence:** confirmed (structural)
- **Where:** `Canvas/GraphCanvasView.swift:166-167` (`.onKeyPress(.delete)`), `:174-184` (arrows), `:471-475` / `:510-515`
- **Scenario:** start dragging a selected node (transaction "Move" open, depth 1), press ⌫ with the button still down: `deleteSelection` runs `begin/end` nested (depth 2→1, so the deletion is *not* its own step), the dragged `NodeView` is removed → the gesture is cancelled without `onEnded` → `endNodeDrag` never runs → "Move" stays open (undo dead) until the next drag's defensive reset commits "Move" — which now contains a deletion. Arrow-nudge during a drag likewise nests into "Move".
- **Fix:** ignore key edits while `dragOrigins`/`commentDrag`/`pendingWire`/`dragMode` are non-nil (return `.ignored`), or make the defensive reset `while model.isInTransaction { model.cancelTransaction() }` and name steps from the change that actually landed.

---

## LOW

### L1. `NodeView` click/double-click thresholds are measured in canvas units, so they scale with zoom
- **Category:** bug · **Confidence:** confirmed · **Where:** `Canvas/NodeView.swift:233` (`abs(g.translation) < 1`), `:245-246` (`≤ 4`), gesture in `.named("canvas")` space (`:215`).
- At zoom 0.15 a 1 px wobble is 6.7 canvas units: a click on a selected node registers as a move (tiny "Move" undo step, selection not collapsed) and a double-click cannot dive into a group; at zoom 4 a 15 px slip still counts as a click. The background double-click (`GraphCanvasView.swift:726, 733`) is correctly in viewport units. Fix: pass `zoom` into `NodeView` (or a `clickSlop` in canvas units = `4 / zoom`).

### L2. `DropResolver.snapRadius` (14) is in canvas units — 2 px on screen at zoom 0.4, 56 px at zoom 4
- **Category:** bug · **Confidence:** confirmed · **Where:** `Canvas/DropResolver.swift:12, 78`; contrast `GraphCanvasView.swift:765, 818` (`hitSize / 2 / zoom`, correct). Fix: pass `snapRadius / zoom`.

### L3. Defensive transaction reset only unwinds one nesting level
- **Category:** bug · **Confidence:** confirmed · **Where:** `GraphCanvasView.swift:387, 473, 530, 584, 590`; `EditorModel+Undo.swift:23-29`. `isInTransaction` is true at depth ≥ 1 but `endTransaction` decrements once; at depth 2 the reset leaves the old transaction open and the new `beginTransaction` *joins* it under the old name. Not reachable today as far as I can trace, but every future nested caller makes it reachable. Fix: `while isInTransaction { cancelTransaction() }` in one shared `resetStrandedTransaction()`.

### L4. Shift-click / shift-double-click on empty canvas ignores the modifier
- **Category:** bug · **Confidence:** confirmed · **Where:** `GraphCanvasView.swift:732-739`. ⇧-click on empty canvas calls `click(at:)` → `clearSelection()` (a ⇧-click that misses should keep the selection); two quick ⇧-clicks open the chooser. Mirror `NodeView`'s rule: read `InputModifiers.selectionMode()` once and only clear/open on `.replace`.

### L5. `MinimapView` recomputes `contentBounds` (O(n) with shape lookups) and redraws every node rect on every transform tick
- **Category:** perf · **Confidence:** confirmed · **Where:** `Canvas/MinimapView.swift:16-18, 26-32`; `viewportRect` changes every pan/zoom tick, and the minimap drag itself writes `canvasRequest` twice per frame (`:44` + `GraphCanvasView.swift:274`). Cache `contentBounds` per `shapesVersion`; draw the node layer once into an image keyed on the graph and stroke only the viewport rect per tick.

### L6. `NodeSearchPopover.results` (a registry sort + definition sort) is recomputed 3–4× per keystroke
- **Category:** perf · **Confidence:** confirmed · **Where:** `Palette/NodeSearchPopover.swift:16, 27, 45-46, 85`. Trivial: compute once at the top of `body` (`let results = results`) and store in `@State` on `query` change.

### L7. iPad: `handleTouch` writes `canvasFocused = true` on every recognizer callback (120 Hz during a drag)
- **Category:** perf · **Confidence:** confirmed (already listed as deferred in handoff §M6) · **Where:** `GraphCanvasView.swift:841`. Guard with `if !canvasFocused`.

### L8. `endWire` fallback `anchors[ref] ?? .zero` draws the pending wire from the canvas origin for a socket without a measured anchor
- **Category:** bug (cosmetic) · **Confidence:** confirmed · **Where:** `GraphCanvasView.swift:587, 592`. Use `anchor(ref)` (`:772`) which has the computed fallback.

---

## Improvements (maintainability)

### I1. Split `GraphCanvasView` (906 lines) along the seams it already has
The file mixes four concerns that are separable without changing behaviour:
1. **Camera** — `transform`, `viewport`, camera persistence, `ScrollWheelCatcher`, `magnifyGesture`, `.fitAll/.fitSelection/.centerOn` (`:24, :44, :100-107, :264-271, :283-288, :309-314, :797-809`). A `CanvasCamera` `@Observable` (or a struct + a small view modifier) owned by the canvas; fixes H1 naturally.
2. **Interaction state machine** — every `@State` from `:26-73` except the camera, plus `beginNodeDrag…endCommentDrag`, `beginWire/endWire/exposeSocket`, chooser and `apply(_ intent:)` (`:469-695, :847-905`). This is already the touch path's `CanvasIntent` interpreter; make it the *only* interpreter (see I2).
3. **Content** — `content`, `commentLayer`, `marqueeOverlay`, `gridDots` as a `CanvasContent` child view with value inputs (M1).
4. **Requests/keys** — `.onChange(of: model.canvasRequest)`, the `onKeyPress`/`onCommand` block, drop destinations.

### I2. Make the mouse path emit `CanvasIntent`s too
Today the touch path is `TouchEvent → TouchIntentMapper → apply(intent)` while the macOS path calls `moveSelection`/`dragComments`/`beginWire`/`click(at:)` directly from four gesture closures spread over `GraphCanvasView.backgroundDrag`, `NodeView.headerDrag/socketDrag`, `CommentMove`, `CommentResizeHandle`. The duplication is real: the same "unselected joins before the move snapshots origins" rule is written three times (`NodeView.swift:224`, `CommentLayer.swift:93`, `TouchIntentMapper.swift:192`); "defensive reset" five times; wire selection twice (`:788-795` vs `:855`); marquee end twice (`:727-731` vs `:886-891`); the ⌥-duplicate and the `pendingDuplicate` dance exist only on the mouse side, so iPad has no duplicate-drag at all. If `backgroundDrag`/`headerDrag`/`socketDrag` produced `.beginMove/.move/.endMove/.beginWire/…` (with a `MouseIntentMapper` that is the macOS twin of `TouchIntentMapper`, taking `InputModifiers` as context), the whole interaction table becomes unit-testable on macOS the way the touch table already is (`TouchIntentMapperTests`), and every latch/teardown bug (H4, M9) is fixed in one place with an `abandon()` like the touch mapper has.

### I3. Measured node frames (see M6) — one `NodeFrameKey` preference beside `SocketAnchorKey` gives `node(at:)`, marquee, culling and the minimap the truth instead of a formula that every new `ParamControl` kind can silently break.

### I4. `NodeView` takes `graph: Graph` only to ask `graph.inputs[ref] != nil` — pass a `Set<String>` of wired input names (or a `wiredInputs` closure) so the node's inputs do not change identity on every unrelated edge change.

---

## What I checked and found clean

- **`CanvasTransform`**: `zoom(by:around:)` keeps the anchor fixed and clamps; `fitting` handles zero-size rects; tests cover round-trips, clamping and fit centring. `toCanvas`/`toScreen` are used consistently (viewport ↔ canvas) at every call site I traced — gestures in the `"canvas"` named space are correctly *unscaled* because the space is declared inside the `scaleEffect`, and the touch path divides `.move` translations by zoom exactly once (`:869`).
- **`TouchIntentMapper`**: latch-once rule, `abandon()` on a second `dragBegan`, pending → latched threshold, mode-specific tap/marquee semantics, delta emission for two-finger pan and pinch — all consistent with the tests (34 cases) and with what `apply(_:)` expects; `dragEnded` without a latch emits nothing (so the tap recognizer owns it). `TrackingPanGestureRecognizer` fixes the slop-offset press point.
- **`TouchInputOverlay`**: `hitTest` hands interactive rects back to SwiftUI using the same transform the canvas draws with; `cancelsTouchesInView = false`; only pan+pinch are simultaneous; the minimap sits in an `.overlay` above the overlay view, so it stays touchable.
- **Transactions on the happy paths**: node drag, comment move/resize, frame-with-members move, plain wire connect, re-drag (`Rewire` + `.disconnect` + `cancelTransaction` on Escape/dismiss), wire-drop chooser (`Connect` held open across the popover, joined by `Add Node`, closed twice, cancelled on dismiss via the `Binding` setter), `+`-socket exposure ordering, `deleteSelection`, `nudgeSelection` — depths balance and `undo()` is correctly a no-op while open.
- **Culling**: `nodesInFlight`/`commentsInFlight` keep gesture owners mounted; in-flight ids keep their z-order; computed `socketAnchor` fallback keeps wires drawn and clickable for culled endpoints (`NodeGeometryTests`).
- **Keyboard**: `Escape` cancels (not commits) a re-drag; arrows nudge as one step; ⇧A requires exactly `.shift`; `Delete` handled both via `onKeyPress` and `onDeleteCommand` is idempotent; ⌘↑/⌘↓/⌘G/⌘D etc. have modifiers and do not collide with canvas `onKeyPress` handlers; the M10 choice of `P`/`,`/`.`/⌘0 avoids Space and Home. `canvasHasFocus` is cleared on unmount and `canvasRequest` cleared with it (the M8 latch bug stays fixed).
- **`ScrollWheelCatcher`**: `hitTest → nil`, window check, bounds check, monitor removed on window change and in `deinit`; the popover's `List` scrolls in its own window so it is not swallowed.
- **Focus teardown in `ParamControl`**: `onDisappear` commits and closes an editing transaction the field would otherwise strand.
- **`DropResolver`**: socket-first with type compatibility, then body, then empty; `+` semantics and wildcard drags match the tests; `firstCompatibleInput` never picks `+`.
- **`PaletteSearch`/`NodeSearchPopover`/`PaletteView`**: ranking is deterministic (id tie-break), definitions filtered by wire compatibility for a wire-drop chooser, tap/double-tap split per platform, `.draggable` payload decodes both id kinds.
- **`DraculaTheme`**: the only hex literals live in `DraculaToken`; `Color(hex:)` is sRGB; the socket/category/accent maps are total.
- **`MinimapLayout`**: `mapRect`/`canvasPoint` are exact inverses; degenerate bounds guarded.
- **Retina**: everything is in points; no pixel assumptions anywhere in the layer.
- **Concurrency**: `nonisolated` is applied exactly where SwiftUI calls off the main actor (`FrameChrome: Shape`, `CanvasTransform`, the mapper enums); `ScrollWheelCatcher`'s monitor uses `assumeIsolated` and returns a `Bool`, not the non-`Sendable` event.
