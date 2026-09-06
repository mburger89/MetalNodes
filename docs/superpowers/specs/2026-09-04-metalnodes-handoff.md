# MetalNodes — Session Handoff

**Written:** 2026-09-04, at a model switch (Opus 5 → Fable 5.1)
**Companion document:** `2026-09-04-metalnodes-design.md` in this directory
**Prior session:** https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF

Read this file first, then the design doc. This file carries what the design
doc deliberately leaves out: where we are in the process, what was *rejected*
and why, and what is still blocking.

---

## 1. Read this before doing anything

**No code has been written and none should be, yet.**

We are on the `superpowers:brainstorming` **architectural** path. Its hard gate:
no implementation skill, no scaffolding, no code until the user approves the
written spec. The spec is written; the user has **not** yet approved it.

The checklist stands at:

```
1. Explore project context ..................... DONE
2. Offer visual companion ...................... n/a (never arose)
3. Ask clarifying questions .................... DONE (5 asked, all answered)
4. Propose 2-3 approaches ...................... DONE (user chose A)
5. Present design in sections .................. PARTIAL — see §2
6. Write design doc ............................ DONE
7. Spec self-review ............................ DONE (4 defects fixed, see §5)
8. User reviews written spec ................... DONE ("looks good lets continue")
9. Invoke writing-plans skill .................. DONE — M0+M1 plan (18 tasks) at
   docs/superpowers/plans/2026-09-04-metalnodes-m0-m1-foundation.md
10. Execute plan ................................ DONE — 18 tasks via subagent-driven
    development on branch m0-m1-foundation; merged to main as PR #1 (1085254).
11. M2 plan ..................................... DONE — docs/superpowers/plans/
    2026-09-04-metalnodes-m2-canvas-interaction.md (16 tasks), approved by the user.
12. Execute M2 .................................. DONE — PR #2 (m2-canvas → main), open.
13. M3 plan + execution ......................... DONE — docs/superpowers/plans/
    2026-09-04-metalnodes-m3-library-viewer-stitchable.md (14 tasks) on branch
    m3-library-viewer (off m2-canvas): 22 commits, 247 tests, warning-free; final review
    + one fix wave + re-review clean. See §10.
14. Next ........................................ finish the M3 branch (PR on top of #2, or
    rebase onto main once #2 merges), then plan M4 (groups).
```

**Terminal state is path-bound.** After the user approves, the *only* skill to
invoke is `superpowers:writing-plans`. Not `frontend-design`, not `swiftui-pro`,
not any implementation skill. Those come later, during execution of the plan.

---

## 2. One process deviation worth knowing

Step 5 says to present the design in sections, taking approval after each. I
presented **section 1 of 5 only** (document model and groups) in chat. The user
then asked for the whole thing as a markdown file they could read in their
editor, so sections 2–5 went straight into the design doc without individual
chat sign-off.

**Consequence:** the user has explicitly reacted only to the document model.
Sections 7–13 of the design doc (type system, codegen, render loop, canvas
interaction, theme, node library) have been *written* but never *discussed*.
Expect substantive feedback there and do not treat them as settled.

Two points I flagged for the user's attention that they have not yet answered:

- **§5 snapshot undo** — granularity is one gesture, not one keystroke.
- **§4.1 the ⌘G cut rule** — deduping group inputs by source socket.

---

## 3. Locked decisions

All of these came from explicit user choices, not inference. Do not silently
revisit them.

| # | Question | User chose |
|---|---|---|
| 1 | Shader kind | **Start 2D fragment, architect so 3D can be added later.** Not 3D now, not SwiftUI-stitchable now |
| 2 | Platforms | **macOS + iPad**, shared engine, two UI layers. User declined "macOS only" and declined "macOS now, iPad later" |
| 3 | Node groups | **Definition + instances, editable in place.** Edit definition → all instances update. Compiles to one real MSL function |
| 4 | Preview | **Main preview panel + a viewer flag movable to any node** |
| 5 | v1 library | **Core set, ~30 nodes** |
| — | Codegen | **Approach A: declarative node definitions + SSA emission.** User confirmed in their own words: "yes, approach A sounds right" |
| — | Live-ness | Parameters live in a uniform buffer; only topology changes recompile. Presented alongside A and approved with it |

### Note on decision 3

The user picked definition+instances but **declined** the third option, which
added a cross-document on-disk library with versioning. So group definitions
live **inside the document only**. Sharing between documents happens through
copy/paste, which carries referenced definitions along (design doc §6). Do not
reintroduce an on-disk asset library — it was offered and turned down.

---

## 4. Rejected alternatives, and why

This is the part that exists nowhere else. Without it you will waste the user's
time re-proposing things they already declined.

| Rejected | Why |
|---|---|
| **3D material graph in v1** | User wants 2D first with 3D reachable later. The `OutputTarget` abstraction exists for exactly this |
| **SwiftUI `[[stitchable]]` target in v1** | Deferred to ~v1.5. Still an open question — see §6 item 5 |
| **macOS-only** | User explicitly wants iPad too, accepting the extra UI work |
| **Groups as visual folders** | Not real reusable functions; user wants true instancing |
| **On-disk cross-document group library** | Offered as option 3 of that question, declined. See §3 note |
| **Per-node live thumbnails** | Offered, declined. Needs N pipelines + N offscreen draws per frame, an atlas, LOD and throttling. Do not sneak it back in |
| **Single-output-only preview** | Too weak; user wants viewer flags on any node |
| **Codegen approach B** (a Swift type with `emit()` per node) | ~60 bespoke types, no data-driven node authoring, definitions not serializable |
| **Codegen approach C** (typed IR + optimizer) | A compiler project bolted onto an app project; Metal's own compiler already optimizes. Deliberately kept *reachable* — the SSA statement list is a minimal IR |
| **Whole canvas drawn in one `Canvas`** | Would mean reimplementing every slider, color well and picker by hand |
| **Command-pattern undo** | Needs a correct inverse for all five group operations; that is where node editors start corrupting state |
| **Golden-image render tests** | Flaky across GPU generations; the per-node compile smoke test covers more for less |

---

## 5. What the spec self-review already fixed

Do not "re-discover" these; they are resolved in the current file.

1. **Yellow meant three things** (Color category, `color` socket, selection
   outline). Selection now uses a `foreground` outline plus glow rather than a
   hue, because every hue is claimed by the type system. Only red (error) and
   green (viewer flag) remain reserved.
2. **The generated-MSL example contradicted §9.2.** It hardcoded `0.5` for a
   second group instance's scale when the rule is that exposed group inputs get
   a per-instance uniform slot. It now shows `u.p0` / `u.p1` per instance and
   `u.p2` shared inside the function.
3. **`comments` was ambiguous** against comment frames. Sticky notes are now
   `stickies`.
4. **The node count didn't add up** — "~30" claimed, 43 listed. Arithmetic and
   trig collapse into one `Math` node with an operation picker, as Blender does.
   Now **33 node types, 47 operations**, which required adding a `variants`
   feature to the `NodeDef` format (design doc §8).

---

## 5b. Second review round (Fable, same session)

After the model switch the user asked for a critical read. Nine changes were
proposed and the user said "fold all nine in"; all are now in the design doc:

1. Sockets addressed by stable name, not index (§3)
2. Edges keyed by input socket — `inputs: [SocketRef: SocketRef]` (§3)
3. Uniform buffer alignment rules, layout returned by codegen, full rebuild on
   publish, generation counter (§9.5, §9.1 example reordered)
4. `bool` producers: Compare, Switch, Constant variants; Reroute added.
   Library is now **36 types / 58 ops** with a Utility category (§13, §12)
5. Viewer-inside-a-definition rule; one terminal per graph (§9.3)
6. `.mnshader` is a **package** (document.json + view.json + textures/);
   `EditorViewState` separated from the document and excluded from undo (§3, §5)
7. Viewer float range is manual min/max in v1, not auto-normalize (§9.3)
8. `GroupDefinition.inputs/outputs` canonical; pseudo-nodes mirror them (§3)
9. Generated-code panel (§11.6); UV convention + static vertex stage (§9.1);
   zoom-to-fit shortcuts (§11.2)

Tests (§14) and milestones (§15) updated to match. The spec is still awaiting
the user's approval — nothing about the gate changed.

## 6. Open questions — still unanswered by the user

Verbatim from design doc §17. Item 5 is the only one that changes the build
order, so ask it first if you ask at all.

1. **Group input editing** — drag-to-reorder and rename for exposed group
   inputs in v1, or is add/remove enough to start?
2. **Textures** — import from file only, or also procedural sources (gradient,
   checker) and pasteboard?
3. **Export** — generated `.metal` source only, or also a precompiled
   `.metallib`?
4. **Time** — wall-clock, or a scrubable fixed-rate timeline with a frame
   counter (better for recording)?
5. ~~SwiftUI `[[stitchable]]` target~~ — **answered 2026-09-04: pulled into v1
   at M3** ("lets pull stichable forward"). Spec §9.5 added.

None of these block writing the implementation plan except arguably #5. The
rest can be resolved at the milestone that needs them.

---

## 7. Repository state

```
branch: main — NO COMMITS YET (git log fails: "does not have any commits")
untracked:
  .DS_Store                     ← should be gitignored
  MetalNodes.xcodeproj/         ← stock multiplatform template
  MetalNodes/                   ← MyApp.swift + "Hello, world!" ContentView
  docs/                         ← the design doc + this handoff
```

Nothing has been committed. The user was offered a `.gitignore` plus an initial
commit and has not answered. **Do not commit without asking** — the harness rule
in effect is that commits happen only when the user asks.

The Xcode scaffold is an untouched template. It contains a `#Playground` block
and `MyApp.swift`, and its build settings need the changes catalogued in design
doc §16 — narrowing `SUPPORTED_PLATFORMS` (it currently includes `xros`), Swift
`5.0` → `6.0`, `MACOSX_DEPLOYMENT_TARGET` `26.6.2` → `26.0`, and a bundle ID off
`devplaceholder.*`. That work is milestone M0.

---

## 8. Suggested opening move

> Read `2026-09-04-metalnodes-design.md`, then ask the user whether they want
> changes — flagging that sections 7–13 were written but never discussed in
> chat, and that open question #5 (SwiftUI stitchable in v1?) affects the build
> order. On approval, invoke `superpowers:writing-plans` and nothing else.

Do not restate the design back to the user as if it were new. They have read
section 1 in chat and have the full file in their editor.

---

## 9. M2 record (canvas interaction, branch `m2-canvas`)

**Rulings made during execution** (the ledger lines, verbatim intent; the spec was the binding authority, the plan its argument):

- T1↔T2 pre-flight: accepted — T1's gate is `--filter ShaderCompilerTests` + Render build; T2 is the very next task.
- Task 1: UI source target (EditorModel.compile call) also breaks between T1 and T2, not only the test fake — accepted for the same reason (T2 is next and fixes both). Cost if wrong: none.
- Task 4: plan defect in commitUndo's handler (redo registered before restore → guard dropped it). Implementer's swap (restore, then register redo with the pre-restore snapshot) accepted. Cost if wrong: redo breaks — covered by singleApplyIsOneUndoStep.
- Task 5: plan defect — #expect(CGFloat == 26 + 16 + 4 * 22) evaluates false under the Swift Testing macro (literal arithmetic typed separately). Fix: single CGFloat-typed literals (130, 1290). Cost if wrong: none. Fix round 1.
- Task 6: fix — capture drag before applying a toggle. Also fixing in this round (cheap, same file): endNodeDrag gated on dragging; stale-transaction reset when a drag starts; canvas focus claimed on appear; spaceHeld reset on focus loss; dangling "M1 note" comm
- Task 8: fix with nested frames (hit 20, layout 10) + revert offsets; also (cheap): node background via RoundedRectangle fill instead of clipShape so the outboard half of the hit area isn't clipped; beginWire resolves type before disconnect and reads a fresh gr
- Task 9: fold Task 4 carry-overs into T9 — (a) `undoStackVersion` observable bumped in commitUndo/undo/redo and read by canUndo/canRedo so menu items refresh; (b) undo()/redo() no-op while isInTransaction. Cost if wrong: menu enable-state only.
- Task 11: synthesise double-click in backgroundDrag.onEnded (≤400 ms, ≤4 pt from last click). Also fixing: chooser placement header-centred like other paths; hoverLocation reset when pointer leaves; ⇧A requires modifiers == .shift. Deferred: double-click on a w
- Task 13: defer duplicateSelection to the first non-zero drag translation. Also fixing: onPasteCommand uses UTType(exportedAs:) so Paste enablement matches canPaste; vacuous edge-rewire assertion; stale comment. Deferred: paste(at:) has no cursor-position calle
- Task 14: fix all three (sync draft on customTitle change; text-bound drafts committed on submit; finite+clamped conversion). Deferred: concreteOrFloat duplicates NodeView.concrete; sourceLabel fallback for non-builtin sources; .required/.uv inputs show nothing
- Task 15: fix — scaleEffect(0.6) before socketAnchor for compact sockets; test asserts a node only visible with the margin (sine at x=440) and excluded at margin 0; also guard viewport == .zero → render all (first frame). Deferred: O(n log n) per render; no soc
- Task 16: `.restore` recompiling on undo/redo is spec §18.3 (table row "restore → topology") — kept; M3 candidate: skip recompile when generated source is unchanged. Cost if wrong: one extra (cached) compile per undo.
- Task 16: onExitCommand kept although unverifiable — Escape never reaches the app as keyDown from the automation tool; the modifier is semantically correct and idempotent with onKeyPress(.escape). Cost if wrong: none observable.
- Final review: four Important findings (transaction leak when a dragged node is culled; background-drag mode re-decided per tick; Escape/chooser-cancel committing a re-drag's disconnect; wires vanishing when an endpoint is culled) fixed in one wave with `EditorModel.cancelTransaction()`, a latched `BackgroundDragMode`, in-flight nodes kept rendered, and `NodeGeometry.socketAnchor` as the wire fallback. `.setSettings` reclassified per spec §18.2 (plan line 614 had pinned the unconditional form).
- Kept as-is: defensive `endTransaction()` resets stay commit-style (a leaked Move is a real user action).

**Manual checks a human still needs to do once** (the automation tool cannot deliver these events): palette drag-in, ⌥-drag duplicate, ⌘-scroll zoom direction, Escape in the chooser / to cancel a wire, pinch zoom.

**What M3 starts from** (in addition to the plan's own tail note): paste at the cursor (⌘V at hover point); skip the recompile on undo when generated source is unchanged (`.restore` is topology per spec table); new nodes render behind neighbours (z-order by UUID — sort selected/newest last); Undo menu title without the action name; ⌘Z inside a text field never reaches the field editor (menu item disabled while the canvas is unfocused); `UTExportedTypeDeclarations` missing for `com.maxburger.metalnodes.nodedef` / `.graph`; `GraphClipboard` decoding not tolerant of missing keys; inspector/canvas `onEditing` asymmetry; `socketUnderPress` classifies input vs output by name; `Graph.remove(node:)` / `GraphClipboard.size` unused in product code.

---

## 10. M3 record (library, viewer, stitchable target, error mapping; branch `m3-library-viewer`)

**Rulings made during execution:**

- Task 1: reserved(_:) body kept unchanged (brief showed only new members) — accepted.
- Task 6: PaletteSearchTests.idMatchesSurfaceLast re-asserted with the exact new order (new titles change the result) — accepted; `#expect(_, "\(def.id)")` comment fix accepted.
- Task 7: PaletteSearchTests category-order assertion now includes .sdf (true consequence) — accepted.
- Task 11: two-node cycle used for the hand check (DropResolver refuses self-connections) — accepted. minors (deferred): dot drag strip is ~4 pt between the two 20 pt socket hit areas (shrink socket hit size for .dot in a follow-up).
- Task 12: two-file export uses an NSOpenPanel folder picker (powerbox grant is per selected URL; a sibling write beside an NSSavePanel result fails under the sandbox) — accepted; minor (deferred): folder path overwrites silently; ExportPanel
- 51:Final review (opus, 8a9f584..c2bb568): 1 Critical — Swift snippet uses `.float2(SIMD2)` etc. which Shader.Argument lacks (only component overloads / CGPoint / CGSize); 3 Important — `.color` slots declared float4 but SwiftUI passes `.col
- Final review: 1 Critical (the Swift snippet spelled vector `Shader.Argument`s with overloads that do not exist — now component-wise `.float2(v.x, v.y)`, with a golden and a `swiftc -typecheck` toolchain-gated test) and 3 Important (colour slots are `half4` parameters read as `float4(name)`; the Reroute dot's socket hit areas shrink to 8 pt so its centre drags; folder export confirms before overwriting) fixed in one wave, plus reserved-word export names, export name committed before Copy/Export, `exportName` regenerating under a stitchable target, an export re-entrancy guard, and no ◉ on output-less nodes. MSL has no implicit `float4`→`half4` conversion: the preview wrapper narrows explicitly.

**Not verifiable on this Mac** (needs a human): the exported `.metal` has never been compiled by the real Metal compiler — the Metal toolchain is not installed (`xcodebuild -downloadComponent MetalToolchain`); the `ShaderExportTests` toolchain-gated test then runs automatically. Also: dragging a Reroute dot (fixed by geometry, not observed), and dropping an export into a real SwiftUI view with a colour + vector uniform.

**What M4 (groups) starts from** — deferred from the M3 review: the compile-skip path keeps generation diagnostics after a failed compile until the source changes; Export is a silent no-op on iPad; nodes not upstream of the terminal have no resolved types (a dangling Reroute shows the `float` colour); the layer-effect help text should say the layer is not sampled yet; the Swift snippet should mention adding the `.metal` to the app target; `drawOrder` allocates `uuidString`s per comparison; pbxproj key order; unwired generic inputs resolved to `color` through a sibling default to `(0,0,0,0)`; `ExportPanelMac` untested (AppKit); ⌘Z inside a text field, `UTExportedTypeDeclarations`, `layer.sample`/Texture Sample (M5) carry over from M2.

## 11. M4 record (node groups; branch `m4-groups`, stacked on PR #3)

**Rulings made during execution** (R1–R24, exhaustive; each with what it costs if wrong):

- R1 T10 owns the `+` socket (as a trailing `SocketDecl` in pseudo-node shapes; `NodeShape.isPlus`) — one field move.
- R2 T7 kept registry-based geometry signatures; T8 switched to `shapes:` closures — one extra refactor.
- R3 Duplicate GroupInput/GroupOutput diagnostics flag every duplicate (the brief's "all-but-first by UUID order" was nondeterministic) — an extra diagnostic row.
- R4 GroupInput emits one SSA variable per exposed input (the pinned golden required it; the brief's prose said "no lines") — two redundant MSL lines per input.
- R5 8-hex node-id prefixes in `u_<8hex>_<param>` / `G_<8hex>_Out` may collide (1/2^32 per pair) — accepted; spec follow-up — a duplicate parameter name in a pathological document.
- R6 Palette-opened viewer keeps the definition's shared slots as uniforms; the brief's `layout.fields…isEmpty` assertion contradicted its prose and §20.4 — one extra uniform in palette previews.
- R7 View variants are selected per dived-through instance, not per definition id (sibling instances must call the normal function) — none; the alternative was a bug.
- R8 Palette-opened definition + dive stack is a valid viewer state; generator anchors at `viewerDefinition`; `diveIn` keeps `editingDefinition` — a spurious "instance no longer exists" for one path.
- R9 `GroupOperations.group` resolves boundary types itself over the whole graph at `path` (`TopoSort.orderAll`), refusing when a type is unknown; no `resolved:` parameter — one resolve per ⌘G.
- R10 The group→ungroup identity test compares structure, not MSL text (TopoSort ties break on random UUIDs) — weaker test.
- R11 Socket names are uniqued/clash-checked per kind (inputs vs outputs separate namespaces) — none.
- R12 An imported definition copy (same id, different hash) is reminted with fresh inner node ids via `GroupDefinition.duplicate(name:)`, shared with Make Unique — none.
- R13 The viewer stores its own route (`EditorViewState.viewerPath`/`viewerDefinition`); `compileNow` uses it; `pruneViewer` walks it. ⌘↑ keeps the viewer; deleting a route instance clears it — two view-state fields.
- R14 `.renameDefinition` is `.topology` (the name is in the MSL function identifier) — a recompile per rename.
- R15 Paste/duplicate into a definition refuse recursion with the notice — none.
- R16 Breadcrumb levels: root 0; a palette-opened definition is level 1; stack entries follow; `exitGroup` pops exactly one level — navigation only.
- R17 Doubled border = node outline (accent, or selection/error colour) + inner 1 pt accent ring clipped below the header — cosmetic.
- R18 In-app hand checks are run by the controller (subagents cannot obtain screen-control grants).
- R19 T9's hand check is subsumed by T11's checklist.
- R20 `GeneratedShader.resolved` is document-wide (every emitted function's map merged) so expose helpers and DropResolver type nodes inside definitions — a larger map per compile.
- R21 `+` accepts any non-texture type (textures cannot be group sockets in M4) — none until M5 textures.
- R22 Re-dragging an existing wire onto `+` yields two undo steps ("Rewire" + "Expose Output") — one extra ⌘Z in a rare path.
- R23 ⇧A popover without definitions is an M5 carry-over (§11.4 annotated) — one placement path missing for a milestone.
- R24 ⌘G drops pseudo-nodes from the selection (like copy/cut/delete); §20.6 amended; Core `group` still refuses them literally — none.

**Fix rounds:** T4 (1), T5 (1), T6 (1), T7 (1 + pre-review fixes), T8 (1), T10 (1); final review → one fix wave (aa22a75, 5fa21fb), re-review clean. 19 commits, 335 tests (Core 188 / Render 24 / UI 123), warning-free, app builds.

**Owed to a human — the T11 in-app checklist was NOT run**: screenshot capture returned nil for the whole session (the separate screen-capture consent card was never approved; the Xcode agent approval was also pending), so the 18 manual checks in the M4 plan (§Task 11 Step 3) are unverified: ⌘G/⌘⇧G/Make Unique/Edit/Exit Group, breadcrumb, double-click dive, doubled border, `+` exposure by drag, wildcard drags, socket rename/remove from the inspector, viewer inside a definition, palette drag-in/Edit/double-click, recursion notice, paste into a definition, stitchable export of a grouped graph. Everything above has unit/GPU coverage except the drawn result and the drag gestures. Run the checklist before merging or log it as accepted risk.

**Deferred minors (triaged by the final review, all "defer to M5"):** `ShaderDocument.node(_:)` sorts definitions per lookup and `model.shape(of:)` re-derives `activePath` per node per frame while dived → plan a `[NodeID: NodeShape]` cache; `GroupFunction.lineOwners` unused; `ShaderGenerator.diagnostics(_:)` is root-only and uncalled (fix or delete); GPU tests never compile `exportSource`; test-only `registry:` geometry overloads (delete); `renameDefinition` has no uniqueness check; PaletteView observes the whole document; `ClipboardMerge.plan` computed twice per paste; repeated identical notices clear early; `setViewer` early-return doesn't re-record the route; compact-mode `+` dot styling; `renameSocket("")` yields the default name; unreferenced definitions still gate the preview through validation (by design, §20.4). Spec follow-up: 8-hex prefix collisions (R5).

**What M5 starts from:** see the plan's closing paragraph (persistence, textures, comments, code panel with group-function line owners, minimap, cross-document paste, ⇧A definitions, shape cache).
