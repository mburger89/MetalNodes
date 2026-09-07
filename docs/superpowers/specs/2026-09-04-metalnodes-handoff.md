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

**T11 in-app checklist — run 2026-09-05 after merge (18/18 observed).** 17 passed as specified; two defects found and fixed on `m4-checklist-fixes`: (F1) group socket labels went stale after rename and duplicated after expose (`renameSocket`/`addSocket` now derive `label` from the name); (F2) the Swift snippet named group-instance slots `p1`/`p2` (`ShaderExport` now looks nodes up document-wide → `groupOut` / `Group · Out`). Observations: ⌘↑ and the other shortcuts are canvas-focus gated, so pressing them right after editing an inspector field does nothing until the canvas is clicked (by design, M2); Cut/Copy/Delete stay enabled for a pseudo-only selection but are no-ops. The Metal toolchain is installed on this Mac now and the exported `.metal` compiles to `.air` — closing the M3 human-only check.

*(Original note, superseded:)* **the T11 in-app checklist was NOT run at execution time**: screenshot capture returned nil for the whole session (the separate screen-capture consent card was never approved; the Xcode agent approval was also pending), so the 18 manual checks in the M4 plan (§Task 11 Step 3) are unverified: ⌘G/⌘⇧G/Make Unique/Edit/Exit Group, breadcrumb, double-click dive, doubled border, `+` exposure by drag, wildcard drags, socket rename/remove from the inspector, viewer inside a definition, palette drag-in/Edit/double-click, recursion notice, paste into a definition, stitchable export of a grouped graph. Everything above has unit/GPU coverage except the drawn result and the drag gestures. Run the checklist before merging or log it as accepted risk.

**Deferred minors (triaged by the final review, all "defer to M5"):** `ShaderDocument.node(_:)` sorts definitions per lookup and `model.shape(of:)` re-derives `activePath` per node per frame while dived → plan a `[NodeID: NodeShape]` cache; `GroupFunction.lineOwners` unused; `ShaderGenerator.diagnostics(_:)` is root-only and uncalled (fix or delete); GPU tests never compile `exportSource`; test-only `registry:` geometry overloads (delete); `renameDefinition` has no uniqueness check; PaletteView observes the whole document; `ClipboardMerge.plan` computed twice per paste; repeated identical notices clear early; `setViewer` early-return doesn't re-record the route; compact-mode `+` dot styling; `renameSocket("")` yields the default name; unreferenced definitions still gate the preview through validation (by design, §20.4). Spec follow-up: 8-hex prefix collisions (R5).

**What M5 starts from:** see the plan's closing paragraph (persistence, textures, comments, code panel with group-function line owners, minimap, cross-document paste, ⇧A definitions, shape cache).

## 12. M5 record (persistence, textures, comments, code panel, minimap; branch `m5-persistence`)

**Process note:** the user asked to parallelise. Core-only tasks with disjoint files ran concurrently in git worktrees (`.worktrees/tN`, branch `m5-tN`) and were landed one at a time by rebase + fast-forward after their own review; UI tasks sharing `EditorModel` / `GraphCanvasView` / `EditorCommands` stayed serial. One rate-limit cutoff mid-run (T6 fix round, T11 review) was recovered from the ledger with fresh dispatches.

**Rulings made during execution** (R1–R26, exhaustive; each with what it costs if wrong):

- R1 Frames hit-test on the title bar and a 6 pt border band only (plan T8), not the whole body (§21.4 wording) — §11.5 / check 16 need marquee and node interaction inside a frame — one hit-test line.
- R2 `.setSettings` stays `.cosmetic`; the model schedules target recompiles itself (§18.2), and manifest edits only touch binding/warnings, which T4/T6 refresh explicitly — a stale preview until the next recompile.
- R3 T1 brief literals corrected: node id `color.mixcolor`; gradient+checker slot count 7; nil-slot order follows post-order DFS emission; Layer Effect export emits `float4(layer.sample(position))` because `half4`→`float4` is not implicit in MSL (§21.2 "uses layer.sample(position)" still holds) — test literals.
- R4 `DocumentSettings.assets` encodes as a sorted `[AssetEntry]` and decodes that one shape only; the plan's "decode both shapes" needed `try?`, which the constraints forbid, and no shipped file has the other shape — a decoder branch.
- R5 A Texture Sample inside a group definition under the Layer Effect target is refused with "Texture Sample inside a group needs the Fragment target" (root samples still export as `layer.sample`); layer-parameter variants of group functions are M6 work — grouped samples cannot export as layer effects until then.
- R6 Parallel worktrees for disjoint Core tasks (see process note) — a hand-resolved merge conflict.
- R7 T3's stray-file test compares against a captured document rather than a second `.sample()` (random NodeIDs) — nothing.
- R8 `GroupFunction.lineOwners` became `lineMap: LineMap` (plan: `bodyOwners: [NodeID?]`); the builder's map is what splice sites consume — a rename.
- R9 T5's whole-string golden uses a deterministic second document (`.sample()` field order is NodeID-random); the sample test asserts header lines with `contains` — a stronger fixture later.
- R10 pbxproj change accepted beyond "keys only": array-valued `CFBundleDocumentTypes` / `UTExportedTypeDeclarations` need an `Info.plist` file, and the synchronized group needs a `PBXFileSystemSynchronizedBuildFileExceptionSet` to keep it out of Copy Bundle Resources (15 insertions, no reorders) — revert to `INFOPLIST_KEY_*`, which cannot express arrays.
- R11 T4's hand-run folded into the T15 checklist items 1–3 — a defect surfaces later than it could.
- R12 Reseed via `EditorModel.reload(package:)` (replace document / view state / textures / missing set, clear undo, recompile), driven by `.onChange(of: file.package)` guarded by comparison — §21.1 did not contemplate Revert To Saved; without it a revert corrupted the next save — one host hunk.
- R13 T8 also edits `EditorModel+Selection.swift` (owner of clear/delete selection) — nothing.
- R14 `addSticky` / `frameSelection` select what they create; `selectComment(.replace)` clears node selection; `addSticky(at:)` takes the top-left and ⌘⇧N offsets by half of `stickySize` — T9 adjusts.
- R15 The two stacked `.dropDestination` modifiers (palette node def + file URL) are settled by hand checks, not code — see "owed to a human".
- R16 `removeAsset` keeps the bytes (manifest-only removal; the writer prunes on save) so undo is lossless; the plan said "and the bytes" — orphan bytes in memory until save.
- R17 The inspector button stays "Choose…" (brief wording; spec says "Choose Image…") — a label edit.
- R18 Stickies draw above wires and below nodes (overturned the implementer's below-wires choice; §21.4 contrast) — a one-line layer move.
- R19 A comment drag moves the whole comment selection; comments copy on their own — accepted.
- R20 T6 notice strings "Drop an image file, not a link" / "That file could not be read" and a 20 pt thumbnail in Assets rows — string edits.
- R21 T9's rebase conflicts against T7 (assets vs comments in `GraphClipboard.extract`, `DocumentChange.insert`, clipboard/apply/request handler) resolved by merging both sides: `extract(_:comments:from:document:textures:)`, `.insert(nodes:edges:definitions:assets:stickies:frames:)`, plus a missing `return` after `.centerOn` — a targeted follow-up.
- R22 (F2) The grouped-sample Layer Effect rule applies only to definitions reachable from the root (`GroupDependencies.reachable`); an orphaned definition after Ungroup must not block the preview — the error appears only once the definition is instantiated.
- R23 (F4) `ShaderCompiler` drops `latestRequested` / cross-client `.superseded`; each `EditorModel`'s generation guard is the sole staleness arbiter — the shared compiler made every second window or reopened document never land a pipeline — a wasted compile on rapid edits.
- R24 (F1) The Color/Distortion refusal "Texture Sample needs the Layer Effect target" is one diagnostic per document, anchored on a root sample; the unused `target:` parameter left `GraphValidator.validate(graph:…)` — re-adding a parameter.
- R25 Final fix wave = the two Important findings plus `TextureStore.evictAll()` on reload (a two-line data-correctness minor); every other minor is carried here — one extra small diff.
- R26 The Test document's 20 "Fragment Output is only valid in the root graph" rows are genuine per-node errors (its definition held 20 Fragment Outputs from paste rounds), not a duplication bug — none.

**Fix rounds:** T2 (1), T4 (1), T6 (1, re-dispatched after the rate limit), T9 (1), T13 (1); T1 had a pre-review ruling fix. T15 in-app checklist → fix wave of five (F1–F5: 1dac7bb, 82840df, 071fc97, 810dc24, 213b735), re-review clean. Final whole-branch review (no Critical, two Important) → one fix wave (5e2540e, 22522e9, 8ec9fda), re-review clean. 31 commits, 459 tests (Core 197 / Render 39 / UI 223), warning-free, app builds.

**In-app checklist (T15, run by the controller with computer-use):** 19 of 20 observed ✅ — New/Save/reopen/Open Sample; Texture Sample placeholder + Choose…; slot sharing and autosaved `textures/`; Assets list remove/prune; grouped sample export with `t_<8hex>` param; Color Effect refusal and Layer Effect `float4(layer.sample(position))`; Gradient/Checker; `.metal` export compiles with `xcrun metal`; cross-document paste carries the image; missing-texture warning + relink; sticky and frame behaviours incl. drawing order and marquee inside a frame; code panel highlighting and group-function line map; minimap pan + persisted toggle; ⇧A definitions and the recursion notice; 103-node drag without a stall. Findings F1–F5 came out of checks 9, 10, 12 and 17.

**Owed to a human — check 5:** Finder → canvas image drop and the palette drag-in regression could not be driven by automation (drag sessions are not deliverable); both `.dropDestination` modifiers are stacked on the canvas and no code-level shadowing was found, but confirm by hand before relying on it.

**Deferred minors (triaged by the final review, all "defer to M6"):** `EditorModel.package` omits `missingTextures` (reseed re-imposes the open-time missing set); `DocumentHostView` still deep-compares texture bytes on each body evaluation; paste never adopts bytes for an asset the destination lists as missing; `TextureStore` re-decodes undecodable bytes on every rebind; `chooseImageAction` built for every param; View menu Minimap is a `Toggle` while Generated Code is a `Button`; `PackageError.undecodable` shows a raw `DecodingError`; `EmitEnvironment.layerExport.textureName` dead path returns `"layer"`; `Emitter.swift` `textureSlots[…]!`; unused `constexpr sampler mn_sampler` in the Layer Effect export; `Graph[comment:]` setter ignores nil; `nudgeSelection` ignores comments; ⌘⇧C disabled and ⌥-drag no-duplicate for comments-only selections; `StickyPane` draft lost on pane disappearance; `openSample()` leaks temp packages; `MinimapView` unculled; `ShaderPackage.encoder` allocates per access; `Data`/file-promise drops not accepted; warning only for slot-bound missing assets; hex literals not tokenised; CodePanel re-tokenises per body; `activePath` re-derived per `shape(of:)` off-root; `reload(package:)` keeps the previous pipeline on screen when the new document fails validation (consistent, but stale until a compile lands).

**Recommendations for M6:** one atomic `PreviewState.program` (pipeline + bindings) instead of two properties kept in step by call order; a single `reachableDefinitions(doc)` shared by both validation branches; move the `DocumentHostView` mirror into a testable `DocumentBridge`; layer-parameter variants of group functions to retire the grouped-sample refusal; an XCUITest or AppKit harness for drag-and-drop so check 5 stops being carried.

## 13. M6 record (iPadOS UI layer: touch canvas, iPad layout, Photos/Files import, Files/Share export, hardware keyboard, XCUITests; branch `m6-ipad`)

**Process note:** the user asked to parallelise again. Every task with disjoint files ran in its own git worktree (`.worktrees/tN`, branch `m6-tN`) and landed by rebase + fast-forward after its own review: wave 1 = T1, T2, T3, T4, T6; wave 2 = T5, T7; wave 3 = T8; then T9 and T10 side by side; T11 last. The plan itself was written by four parallel writers against one shared interface contract (the plan exceeded a single writer's output budget). One rate-limit cutoff hit T10's implementer mid-task; it was resumed on its own transcript with its uncommitted worktree intact. Rule kept from M5: rebase via `git -C .worktrees/tN rebase m6-ipad`, merge and remove from the main checkout — running the merge from inside a worktree and then removing it kills the shell's cwd.

**Rulings made during execution** (R1–R24, exhaustive; each with what it costs if wrong):

- R1 `DocumentBridge` exposes `mirror(into:)` instead of the spec's version counter; the host keeps its three `onChange` watchers (what M5 validated) — a small host refactor. §22.6 was edited to match.
- R2 Parallel worktrees per the process note — a hand-resolved rebase conflict.
- R3 T7 (touch overlay) and T8 (iPad layout) verify by builds only; no unit test can drive UIKit recognizers or `NavigationSplitView` — T10's XCUITests and T11's checklist are their tests — a defect surfaces one task later.
- R4 `DocumentBridge.apply`'s equality guard omits `missingTextures` (derived from `textures/` + manifest on read; no file write can change it alone) — one extra comparison.
- R5 `fileExporter(… contentTypes: [.folder])` (plural): the iOS 27 SDK routes the singular label to a `WritableDocument` overload `FileDocument` does not satisfy — a label edit.
- R6 Interactive rects are reported in the "canvas" named coordinate space and converted in `hitTest`; recognizer simultaneity is limited to two-finger pan + pinch; the viewer badge's identifier is `badge.<hex8>` with no socket name; there is no `toggleViewer` intent (the badge is a SwiftUI pass-through, not a mapper hit); `StickyView` has no on-canvas text field and no gear button, so nothing to pass through — spec-text deviations where the brief won.
- R7 T5's Photos picker cancel-vs-pick race fixed structurally (yield one turn before the cancel check) plus a T11 "pick a large photo" check — a generation token later.
- R8 iOS "Open Sample Shader" opens the temporary package through `@Environment(\.openURL)`; `openDocument` is macOS-only in SwiftUI — the fallback is a `UIDocument`-based open (T11 check 2 confirms).
- R9 `UISupportsDocumentBrowser` and `LSSupportsOpeningDocumentsInPlace` (both YES) added to `MetalNodes/Info.plist` in T10, the app-target task; the brief omitted them and the iOS build warned — two plist keys.
- R10 Share hands over the export folder for every target (the Fragment target's single `.metal` included) as one `Transferable` `ExportShareItem`; codegen runs on transfer, not in `body` — a per-target representation.
- R11 Disabled `Commands` yielding shortcuts to a focused `TextField` on iPadOS is settled by T11 check 14, not code.
- R12 T10's overlay defect (a socket drag latched as a pan: `.began` reconstructed the press point a slop past the 10 pt grab radius) was fixed inside T10's fix round with the file list extended to `TouchInputOverlayPad.swift`; a `UIPanGestureRecognizer` subclass records the touch-down point — a one-file revert.
- R13 `testPaletteDragPlacesANode` throws `XCTSkip` on macOS (XCUITest cannot start an AppKit `NSDraggingSession`) and runs on iPad; the macOS palette drag-in joins the hand checks — one skip to remove.
- R14 A context-menu press on an unselected node (body or socket) adopts it as the selection before an item acts, on both platforms; the brief's iPad check 13 expects Ungroup/Edit Group enabled on a long-pressed instance, and macOS convention agrees — the items enable against the bare selection again.
- R15 No `DocumentGroupLaunchScene`: with it in place, one view-state write sent the document binding into an endless re-publish loop on iPadOS 27 (hundreds of host re-renders per second, no writes of ours) and the app hung. Browser-first launch, the split view's detail bar hidden, the toolbar hoisted to the document bar, the mode picker in the breadcrumb row — one scene and one modifier to restore.
- R16 iPad's Open Sample Shader is a file installed into On My iPad › MetalNodes at launch and opened from the browser (§22.4 amended): `openDocument` is macOS-only, `openURL` refuses file URLs from tmp and Documents alike, `NewDocumentButton`'s `prepareDocumentURL` is never invoked for a `FileDocument` group on iPadOS 27 and its `contentType` is ignored; `DocumentCreationSource` needs the iOS 27 `Document` protocol, which Xcode Cloud's 26.6 cannot build — one static func and one init call.
- R17 One set of platform services per window, created next to the bridge: `EditorServices.platform` is computed, and the pickers are SwiftUI presentations bound to those objects — a presenter rebuilt by the next render dismissed the picker it had just opened.
- R18 View-state-only mirror writes bump the change count of the platform document directly (`NSDocumentController.document(for:)` on macOS, the `NSFileCoordinator.filePresenters` `UIDocument` on iOS); a registration made to mark them would wipe the redo stack (verified in a unit probe). `undo()`/`redo()` skip unnamed groups — one helper to replace.
- R19 The iPad toolbar carries a View menu (Minimap, Generated Code): the iPadOS menu bar and ⌘⌥C need a keyboard or a pointer, so the two toggles had no touch route.
- R20 The fragment target's Export to Files uses a dynamic `.metal` content type (`UTType.metalSource`); under `.sourceCode` the system wrote `metalNodesShader.metal.txt`.
- R21 (final review C1/I1) The host marks the platform document changed on *every* non-empty mirror write, not only view-state-only ones: a same-image relink changes the bytes and nothing else, and an edit's own undo step reaches the document only while the window's manager is adopted — a second mark for an edit that already carries a step costs nothing.
- R22 (final review I2) iOS's `CommandGroup(replacing: .pasteboard)` stays as T9 built it, gated on canvas focus; whether a focused text field keeps ⌘X/⌘C/⌘V on a hardware keyboard is owed to a hardware check (the Simulator drops synthetic keys in capture mode and routes ⌘ keys to Simulator.app otherwise) — the §22.5 responder-based implementation is the fallback.
- R23 (final review I3) A late `ExporterPad.finish` resolving the *next* request is deferred to M7 with the analogous `ImageChooserPad` note: one generation token in `PickerPresenter` closes both, and neither is reachable without a second request inside the first sheet's completion.
- R24 The iPad long-press XCUITest presses an empty normalized point below the graph; the canvas centre lands on a node's slider in the sample fixture, and a param control keeps its touches (spec §22.2).

**Fix rounds:** T5 (1), T6 (1), T7 (1), T8 (1), T10 (1, pre-review: overlay press point + macOS skip); T1–T4, T9 clean. T11 checklist → nine fix commits (ad101d6 same-source compile shortcut ignored the slot map [pre-existing since M5]; caf4380 file mirror out of the undo stack [pre-existing since M5]; 356e0a9 context-menu adoption; 344cd9a/2f679d1 iPad bars, launch scene, sample file; d8cf8da services per window; a990d11 view-state dirty mark, View menu, `.metal` export name). Final whole-branch review (opus; one Critical, three Important) → one fix (e0d0348) closing C1 and I1, rulings R22–R23 on I2/I3, scoped re-review clean. 28 commits, 249 / 40 / 236 package tests + 8 XCUITests (iPad 5, macOS 2 + 1 skip), warning-free, three builds (macOS, iOS Simulator, Xcode 26.6 macOS).

**In-app checklist (T11, run by the controller with computer-use on the iPad Pro 13-inch simulator, iPadOS 27):** 17 of 20 observed ✅ after the fixes — document browser new/open/save/reopen; the sample from On My iPad; tap/wire/badge/deselect; one-finger node drag with one undo step and the 6 pt floor; wire drag to a body and to empty canvas with the compatible-only chooser; one-finger pan; select-mode marquee add / tap toggle / kept selection; lasso replace with "3 nodes selected"; double-tap chooser with typed "mix"; ✛ at centre, fit all / fit two, minimap tap, Minimap toggle persisted (via the View menu); long-press menu with adoption, Paste at the press point, sticky centred, moving press opens nothing; inspector title/slider/enum with the slider not recompiling, inspector hidden state persisted; Photos (incl. a 3000² photo) and Files import upright, cancel leaves the node, missing-texture warning and relink; Export to Files as `.metal`, Share sheet with the folder, "The graph has errors" alert; Generated Code under the preview with Copy; Layer Effect export of the grouped sample with a Texture Sample inside (`…_layer(`, `float4(layer.sample(position))`, no `texture2d`, compiles with `xcrun metal`). Not observed: two-finger pan and pinch (8, half of 7 — not drivable from a mouse; T10's pinch test covers the zoom), hardware keyboard (14 — the Simulator drops synthetic keys in capture mode and routes ⌘ keys to Simulator.app otherwise; the command wiring is unit-tested in T9), compact width (19 — Slide Over / Split View cannot be produced in the Simulator from this session). macOS regression subset: M5 1–4 ✅ (4 after ad101d6), 12 ✅, 17 ✅, M4-8 ✅ (after caf4380), M4-17 ✅, right-click canvas menu ✅ (after 356e0a9); M5-5 Finder drop and the palette drag-in are not deliverable by automation.

**Owed to a human:** macOS Finder → canvas image drop (M5-5) and the palette drag-in (the T10 skip); on an iPad with a keyboard, check 14 (⌘Z/⇧⌘Z, ⌘C/⌘V at the viewport centre, ⌘A, ⌫, arrow nudges, ⇧A, Escape, and ⌫ inside a focused parameter field); two-finger pan in all three modes and pinch about the fingers with the LOD swap; Slide Over / Split View compact width (19).

**Deferred minors (per task; the final review's triage in brackets):**
- T1: before/after `#expect` comparisons in two `PreviewStateTests` (brief-mandated).
- T2: spec §22.6 still says `@Observable` on `DocumentBridge` (the class has no macro); no test for a package differing only in `missingTextures`.
- T3: a disconnected sampling instance under Layer Effect export leaves an uncalled `texture2d` group function in the export (variant loop keyed off root `textureRequests`, not reachability); `Emitter` falls back silently to texture args under a layer env when no variant exists (should be a `GenerationError`); layer-sample spelling duplicated in `EmitEnvironment`; `GroupFunction.isLayerVariant` never read; handoff §11 R5 wording now stale (grouped samples do export as layer effects).
- T4: `EditorView.swift:11` comment says "chooser" for the exporter flag; no explicit reentrancy guard on `chooseImage`/`relink` (the Mac path is synchronous).
- T5: two near-duplicate `fileExporter` calls; png-fallback comment; a stale deferred dismissal check could in theory resolve a later request (unreachable in practice).
- T6: long-press after a latched drag untested (the overlay's `allowableMovement` makes it unreachable).
- T7: one-finger drag threshold is UIKit's pan slop (~10 pt), not the spec's 6 pt; indirect-pointer (trackpad/mouse) touches not accepted; `.accessibilityElement()` on socket anchors adds unlabeled VoiceOver stops on macOS (add a label); `interactiveRects` churn during pans.
- T8: segmented mode picker shows titles rather than SF Symbols; context-menu popover rows have narrow tap targets; unused `device` / `import MetalNodesRender` in `EditorViewPad`; `canvasColumn` dead on iOS; iOS single-tap palette row vs the inner Edit button; the temporary sample package is not cleaned up on refusal (macOS pre-existing); the share folder name is now sanitized.
- T10: `TrackingPanGestureRecognizer.initialLocation` only recorded when nil (record whenever `state == .possible`); `handlePan`'s `as?` cast and the slop-offset fallback are dead (type the handler parameter); `connected` staticTexts query app-wide, not inspector-scoped; `toggleInspector` asserts nothing; macOS `nodeCount` branch and the skipped test body unexercised; `BackButton` UIKit-internal identifier; `LaunchFixture` reads `UserDefaults` not `ProcessInfo.arguments`; `com.maxburger.metalnodes.nodedef` UTType not exported in Info.plist (pre-existing warning; a possible cause of the AppKit drag never starting under XCUITest); no test queries `badge.<hex8>`.
- Final review (deferred, all to M7): `PlatformDocument`'s macOS `keyWindow` fallback can mark the wrong untitled window, and the iOS `filePresenters` lookup marks one `UIDocument` when a file is open in two scenes; the first one-finger `.pan` delta is the whole translation since touch-down (~10 pt jump); `canvasFocused = true` written on every touch event; interactive rects tested without z-order; context-menu adoption skips comments; `textureSlots` docstring stale; every Share leaks a `tmp/Exports/<uuid>/` folder; `ExporterPad`'s single-file branch takes `files.first` where the Mac panel looks for the `.metal`; the palette drag-out has no iPad XCUITest; `toggleInspector` asserts existence only; `PreviewProgram` is not `Sendable` where §22.6 says so (fix the spec); the uncalled `texture2d` group function in a Layer Effect export, the silent `"layer"` fallback, `isLayerVariant` unread, unlabeled socket accessibility elements, and the layer variants' `requiredStdlib` not merged (a superset today).
- T11: the node chooser popover is pushed off-screen by the software keyboard when opened near the bottom edge (6, 11); the canvas menu popover is clipped at the bottom edge (`arrowEdge: .top` fixed; let the system pick); the first document opened after a cold launch sometimes shows the split view's column bars under the document bar (intermittent; hiding the sidebar bar did not remove it — a plain trailing column instead of `NavigationSplitView` would); the one-finger pan drops the recognition slop and the first move event; Recents in the document browser lists documents a test run deleted until they are tapped; the unused `constexpr sampler mn_sampler` warning in the Layer Effect export (M5 deferred).

**Recommendations for M7:** adopt the iOS 27 / macOS 27 `Document` protocol once Xcode Cloud runs Xcode 27 — it brings `DocumentCreationSource`, which is the supported way to give the iPad a real "Open Sample Shader" door, and `URLDocumentConfiguration` retires the `NSFileCoordinator.filePresenters` lookup in `PlatformDocument`; replace `NavigationSplitView` on iPad with a plain three-column layout (the first-open bar glitch and the `.inspector` overlay both go away); a generation token in `PickerPresenter`; a 6 pt custom pan threshold via a `UIGestureRecognizer` subclass and indirect-pointer support on the overlay; keyboard-avoiding placement for the chooser and canvas-menu popovers; a `GenerationError` for the missing layer variant and retire `isLayerVariant`; labelled socket accessibility elements; export the `nodedef` UTType and retry the macOS palette-drag XCUITest.
