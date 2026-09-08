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

**Rulings made during execution** (R1–R25, exhaustive; each with what it costs if wrong):

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
- R25 (re-review) The host marks the platform document only for mirror writes without a document change — a document write rides the model's own undo step, which NSDocument counts and counts back on undo; view state and bytes alone (the same-image relink) are the host's to mark — if wrong, one predicate.
- R24 The iPad long-press XCUITest presses an empty normalized point below the graph; the canvas centre lands on a node's slider in the sample fixture, and a param control keeps its touches (spec §22.2).

**Fix rounds:** T5 (1), T6 (1), T7 (1), T8 (1), T10 (1, pre-review: overlay press point + macOS skip); T1–T4, T9 clean. T11 checklist → nine fix commits (ad101d6 same-source compile shortcut ignored the slot map [pre-existing since M5]; caf4380 file mirror out of the undo stack [pre-existing since M5]; 356e0a9 context-menu adoption; 344cd9a/2f679d1 iPad bars, launch scene, sample file; d8cf8da services per window; a990d11 view-state dirty mark, View menu, `.metal` export name). Final whole-branch review (opus; one Critical, three Important) → one fix (e0d0348) closing C1 and I1, rulings R22–R23 on I2/I3; the scoped re-review caught the fix over-marking document writes against NSDocument's undo-driven change count (window Edited after undoing everything) → bb739bc marks only writes without a document change (not visually re-confirmed on macOS: screen capture stopped for the session). 28 commits, 249 / 40 / 236 package tests + 8 XCUITests (iPad 5, macOS 2 + 1 skip), warning-free, three builds (macOS, iOS Simulator, Xcode 26.6 macOS).

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

## 14. M7 execution record — RealityKit material target (2026-09-07)

Branch `m7-realitykit` off `main` @ 7cf595f. 34 commits. 659 package tests (Core 334 / Render 69 / UI 256) in 50 suites, warning-free, four builds green (macOS on Xcode 27.0 and on Xcode 26.6 — the Xcode Cloud toolchain — plus the iPad Pro 13-inch simulator). Spec §23; amendments in §23.10. Fifteen tasks, subagent-driven, with worktrees for the disjoint ones.

**What shipped.** A fifth output target: a RealityKit `CustomMaterial` emitted as two `[[visible]]` functions from one graph — a per-fragment surface shader and a per-vertex geometry modifier behind a single Material Output node — plus a 3D preview that runs the same emitted statements on a lit procedural mesh, and a `.metal` + `.swift` export. Ten new 3D input nodes, a stage model on `NodeDef`, seven validation rules, four procedural meshes, an orbit camera, and a GGX approximation of RealityKit's `.lit` model.

### 14.1 Rulings taken during execution

- **R1** — Tasks 6 and 8 ship their acceptance suites with `.disabled(…)`, enabled by Task 9. Every task must end on a green suite; a knowingly-red one makes each later full-suite step ambiguous.
- **R2** — Tasks 4 and 10 ran in parallel worktrees against the Task 1→2→3 chain, on provably disjoint file sets.
- **R3** — `MeshVertex` is 80 bytes, not the plan's 64. Both `SIMD3<Float>` and `float3` cost a full 16.
- **R4** — Two `MaterialPreviewCodegenTests` assertions could not fail as written (they matched text emitted unconditionally); Task 9 tightened them when it enabled the suite.
- **R5** — Task 14's in-app visual check moved to Task 15's checklist: the machine's screen was locked and an agent may not unlock it.
- **R6, corrected** — the preview's `unused variable` warnings are *not* safely deferrable. The first reading was that `EditorModel` discards compiler diagnostics; that holds only for the `.success` branch. The `.failure` branch maps every line including node-less warnings into `diagnostics`, and `EditorView` renders them unfiltered, so a genuine compile error arrives with the noise beside it. Fixed by gating all three shim declarations.
- **R7** — the depth attachment is unconditional on every pipeline rather than gated on the view, because the view outlives programs and a dived viewer under `.realityKit` yields a `.fragment` program.
- **R8** — viewing a geometry-only node is refused rather than widening the geometry order, because §23.5 makes a viewed value fragment-stage colour on the mesh.
- **R9** — the warning at `MetalNodesApp.swift:33` stays for M8: identical on `main`, inherited M6 debt.

### 14.2 Defects review caught that tests did not

Worth recording, because each was invisible to a green suite:

- `ParamValues.mslLiteral`'s int branch trapped on NaN/infinity/out-of-range where the byte writer guarded, and the two rounded differently — one stored `2.7` would write byte `3` and export literal `2`. Both paths now share one coercion.
- The **sphere's triangle winding was inverted** relative to its own normals — 0 of 2208 triangles consistent, while cube/plane/torus were 100%. `gridIndices` is shared, but the sphere's φ ran the opposite way. Under back-face culling it rendered inside-out.
- The exported Swift snippet always emitted `variable 'material' was never mutated` — a warning in every user's project, because every mutating line was commented out.
- The generated vertex function referenced an undeclared `params`: the geometry environment spells `time` as `params.uniforms().time()`, correct for the exported modifier, but the preview's vertex function has no `params`. **The starter document was the first graph in the milestone to read Time in the geometry stage.**
- **`PreviewView` attached a depth buffer for every target while only 3D pipelines declared one**, so under Metal API validation — on by default for Xcode's Debug Run — *any* 2D document aborted on the first frame. This came from the plan, so no per-task reviewer had standing to question it, and it would have stopped the in-app checklist at step 1.
- A 3D input node inside a group definition was accepted and emitted `/* ?sys.worldPosition */` into a real exported `.metal`.
- `OrbitCamera.dolly` had no caller: the spec's scroll/pinch dolly never existed, and a unit test on the method in isolation made it look done.

Two tests were caught passing for the wrong reason: a compile test that wired only the last of six nodes (the other five dead-code-eliminated before codegen), and a validation fixture whose node was never wired to the group output — masking the very bug it named.

### 14.3 In-app check — run 2026-09-07, after the merge

Run on macOS against the RealityKit Material sample. **Verified working:**

1. The sample opens and reports "No problems"; a lit sphere renders with a correct specular highlight and falloff.
2. Dragging the preview orbits the camera — the highlight tracks, and no jump on re-drag.
3. Scroll dollies, both directions.
4. Mesh picker: Sphere, Cube and Torus all render correctly. The torus reads properly — hole visible, far side occluded by depth, no inside-out faces, which is the sphere-winding fix confirmed visually.
5. Lit ↔ Unlit round-trips: Unlit renders black, which is correct — the sample wires nothing into Emissive, and the unlit program returns `float4(emissive.rgb, opacity)`.
6. The viewer flag renders the viewed value as flat unlit colour on the mesh, with the min/max range control beside it.
7. Position Offset genuinely displaces geometry: raising the amplitude to 0.60 visibly deforms the silhouette; at 10.0 the vertices leave the frustum entirely.
8. Undo/redo across a lighting-model change works and recompiles.
9. The inspector carries the honest caption about the GGX approximation.
10. All four meshes render: the Plane is a correctly-lit quad in perspective, front-facing rather than culled.
11. **Copy Swift snippet** produces the real snippet — `NoMetalDevice` declared locally (no reference to the non-existent `CustomMaterialError` case), `let` rather than `var`, both shader objects built, the picker's lighting model carried through, and the `boundsMargin` helper present because this graph wires Position Offset.
12. **Export…** names both files in the panel and writes both. The `.metal` carries the baked-parameter header naming each value's node and parameter, and **compiles cleanly against the real RealityKit SDK** (`xcrun -sdk macosx metal -c`, exit 0, no warnings). The geometry function keeps `params.uniforms().time()` live while baking the amplitude to `0.06` — exactly the parameter split §23.6 specifies.
13. Save, close and reopen restores the mesh, the camera, the target and the lighting model from the file.

**One defect found, fixed, and verified in the same session** — see §14.5.

**Still not checked:** the macOS and iPad regression subsets from §22.8. The full list is in the plan's Task 15, Step 3.

### 14.4 Owed to a human
- Everything M6 owed (handoff §13): macOS Finder→canvas drop, palette drag-in, iPad hardware-keyboard check 14, two-finger pan/pinch, Slide Over compact width.

### 14.5 The defect the in-app check found

Switching Lighting between Lit and Unlit changed nothing on screen. `EditorModel.perform`'s `.setSettings` branch decides by hand which fields need a rebuild — it listed `fastMath`, `target` and a stitchable `exportName`, but not `lightingModel`. The codegen was always right (the two programs genuinely differ; the GGX helpers vanish under Unlit); the UI simply never asked for the new one.

Fixed in `2e901b3`. The deeper problem is that nothing enforced the correspondence between that hand-maintained list and what actually reaches codegen, so `4f1df20` adds `everySettingThatReachesCodegenRecompiles`, which asserts both directions — every codegen-relevant setting rebuilds, every cosmetic one does not — and fails against the pre-fix code. Add a row whenever a setting starts or stops affecting the generated source.

This is the same shape as the shim/`materialSys` correspondence in §14.6 item 1: two lists that must agree, with nothing checking that they do.

### 14.6 What M8 starts from

1. **Tie the shims to `materialSys`.** Three shim structs and two emit environments encode the same RealityKit vocabulary independently; a key added to one and missed in the other yields a comment marker in generated MSL. That is the shared cause of both new §23.7 rules. A single table, or a test asserting every `materialSys` key has a matching shim accessor, retires the class.
2. **Stage/target legality lives in four places** — `NodeDef.stages`, `MaterialValidation.twoDimensionalOnly`, the derived `material3D` set, and each environment's implicit `sys` vocabulary. One predicate — "can node N be emitted in environment E" — asked at every emission site would have caught both late findings.
3. The M6 debt list, deliberately excluded from M7.
4. **Live material parameters**: map up to four exposed floats onto `params.uniforms().custom_parameter()` so an exported material animates from Swift without re-export.
5. **Clearcoat**, with its three sockets and lighting model.
6. `set_custom_attribute` as the one channel from the geometry stage to the surface stage.
7. Re-orthonormalise the TBN basis (Gram-Schmidt) whenever a non-identity model transform lands; the tangent and normal transform by different matrices.
8. Consider `MTL_DEBUG_LAYER=1` on CI's test step — the suite passes under it today, and it would make the "every pass carries depth" invariant self-enforcing.
9. Migrate the dolly's source-text test to the `MetalNodesAppUITests` target, which can drive real scroll and pinch.
10. Then the two milestones already sequenced with the user: custom code / expression nodes, and a cross-document node library.

## 15. M8 execution record — custom code and expression nodes (2026-09-07)

Branch `m8-custom-code` off `main` @ `ddc6527`. **45 commits** on `m8-custom-code` across Tasks 1–18, plus Task 19's two (the sample document and this record) on `m8-t19` — **47 once this branch lands**. **919 package tests in 118 suites** — Core 531 / Render 77 / UI 311 — up from **667 in 86 suites** at the branch point (Core 337 / Render 70 / UI 260). Warning-free. Spec §24; amendments in §24.10. Nineteen tasks, subagent-driven, with worktrees for the disjoint ones and five parallel waves.

**Four builds, all green, all run on this branch at `f13ea75`:**

| Build | Result |
|---|---|
| `swift build --package-path MetalNodesKit` (clean, `.build` removed) | **0** lines matching `warning:` |
| `swift test --package-path MetalNodesKit` | 311 UI / 77 Render / 531 Core, **all pass** |
| `xcodebuild -scheme MetalNodes -destination 'platform=macOS'` under **Xcode 26.6 (17F113)** | **BUILD SUCCEEDED** |
| `xcodebuild -scheme MetalNodes -destination 'generic/platform=iOS'` under **Xcode 26.6** | **BUILD SUCCEEDED** |

The two `xcodebuild` runs are the first in this milestone to compile the **app target** — every prior task built only the package. The iOS build succeeds with five pre-existing deployment-target warnings (`IPHONEOS_DEPLOYMENT_TARGET` is 27.0; Xcode 26.6 supports up to 26.5.99). They come from `MetalNodesKit/Package.swift` and the project file, both set at `2d02436` when the package was created, and they appear on Xcode Cloud too. Not introduced by M8, and not fixed by it.

`MetalNodes.xcodeproj/project.pbxproj` was **not** rewritten by either build and is not in any commit; `git status` was checked after each.

### 15.1 What shipped

**Two new node kinds.**

- **The Expression node** (`utility.expression`, spec §24.2). A one-line formula whose *input sockets are the free identifiers it names* — `a * b + 0.5` grows sockets `a` and `b`, each with its own generic `T0…Tn`, so a `float2` and a `float` can meet in one expression. The output type is a picker. The formula is instance data, not a definition, so two Expression nodes are independent. It emits as a single inlined statement, never a function call. Identifier substitution goes through `MSLScanner.tokenise`, which is why `col.rgb` survives (a `\b`-bounded regex never matches `col` there at all — `.` between letters is not a Unicode word break) and `a + b.a` does not become `{in.a} + {in.b}.{in.a}`.
- **The Custom MSL definition** (spec §24.3). `GroupDefinition.body` became a `DefinitionBody` enum — `.graph(Graph)` or `.msl(String)` — so a definition is either a subgraph or hand-written Metal, editable in place via ⌃⌘N and a dive-in code editor. One function per definition no matter how many instances. Inputs reach the body only as `in_<name>`; outputs are assigned by their declared names, and the user's text is never rewritten. Hand-written bodies are guarded by `MSLScanner` (scope breakers, preprocessor directives, unbraced loop bodies) and `LoopHardening` (a per-loop iteration budget spliced at a character offset, with brace-wrapping where the loop sits in an unbraced statement slot). Compile errors map back to the **user's own line** through `LineMap`.
- **The Custom MSL feature's one real capability limit**, and it is not obvious: a hand-written body **cannot name `params.geometry()`, `params.surface()` or `geo.*` under any target**. A definition emits as a *group function* whose signature is `(float2 uv, float time, float2 size, float2 mouse, …)`, so those roots are simply not in scope there — `params` is a RealityKit material-function parameter, and `geo` is a local the material function hoists. Spec §24.5 was written on the opposite premise ("a hand-written body names `params.geometry().normal()` directly"); Task 11 found it by compiling a real export (`error: use of undeclared identifier 'params'`), and **§24.10 amends the spec**. The environment a `.msl` body is checked against is `EmitEnvironment.groupFunction`, not the document's target.

**The legality seam, retired.** M7 left "can node N be emitted in environment E" answered in four independent places — `NodeDef.stages`, `MaterialValidation.twoDimensionalOnly`, a derived `material3D` set, and each environment's implicit `sys` vocabulary (§14.6 item 2). M8 replaced them with **one predicate**, `EmitEnvironment.canEmit`, keyed off `SysValue.readable`, with `NodeDef.stages` now *derived* rather than declared. The migration test earned its keep immediately: `input.mouse` and `input.resolution` **declared** `MaterialStage.all` and **derive** `[]` — the declaration had been wrong all along, and only a separate rule-3 list had been preventing a Mouse node under RealityKit from emitting `v0 = float2(0.0, 0.0);`, a plausible-looking constant rather than a compile error. One deleted line from a silent wrong value.

**Three RealityKit follow-ups** (§14.6 items 4–6).

- **Live material parameters** (§24.6): up to four exposed floats map onto `params.uniforms().custom_parameter().x/.y/.z/.w`, so an exported material animates from Swift without re-export. Both the marking predicate and the export both go through one `UniformLayout.liveField(for:)`.
- **Clearcoat** (§24.7): a third lighting model with three sockets and a second specular lobe in the preview. `set_clearcoat_normal` is emitted **only when its socket is wired** — the SDK marks it `availability(macos, introduced=15.0, strict)`, and `strict` makes it a hard compile error, so an unwired clearcoat export at `-mmacosx-version-min=14.0` would have broken the user's own Xcode build.
- **`set_custom_attribute`** (§24.8): the one channel from the geometry stage to the surface stage, as a terminal socket and a reader node, interpolated in the preview.

**A sample document.** `ShaderDocument.customCodeSample()` — a RealityKit material whose roughness is an Expression (`clamp(uv.x, 0.05, 0.95)`) and whose base colour passes through a Custom MSL definition. It joins the library sweep, and its export is compiled with real `xcrun metal` on both a material and a fragment termination.

### 15.2 Rulings taken during execution

Twenty-eight, exhaustive, each with what it would cost if wrong. Two were made before any task ran (pre-flight conflict scan); **P1 was withdrawn and ruling 25 was reversed**, both said plainly below.

**Pre-flight.**

- **P1 — WITHDRAWN.** Task 9's Expression call site should assert `precondition(lines.count == 1)`, so the "one template line = one user line" assumption fails loudly. *Withdrawn:* a legal one-line formula containing a braced loop expands to several lines once Task 8 hardens it, so the precondition would have **crashed on input the milestone accepts** — demonstrated with `for(int i=0;i<4;i++){x+=1.0;}`, which yields four lines. Crashing on user text contradicts this milestone's own "never refuse legal code" principle. The assumption needed a graceful guard, not a trap. *Cost had it stood:* a hard crash in codegen on a formula a user is allowed to type.
- **P2.** Task 12 must *also* extend `EditorModel`'s `.setSettings` recompile condition and the `everySettingThatReachesCodegenRecompiles` matrix with `liveParameters` — the plan attributed this to Task 12 but omitted it from Task 12's file list. *Cost if wrong:* nothing; it adds a row to a test that already exists. (That matrix is M7's §14.5 guard, working as designed.)

**During execution.**

1. **Fix both the preprocessor miss and the do/while overcount inside `MSLScanner`**, in Task 2, rather than deferring them to Tasks 7 and 8. `/* c */ #include <x>` passed the scan, and C strips comments in translation phase 3 *before* directive recognition in phase 4 — a genuine `#include` reaching codegen unrefused. The do/while overcount was called "safe (extra bound-checks)"; it is not, once Task 8 lands, because the spurious site is the `} while (b);` closing test and the inserted `break` would land in the **enclosing** scope. *Cost if wrong:* a comment-stripping pass could over-strip a `//` inside a string literal; MSL has no string type.
2. **`float a, b;` binds only `a`, leaking `b` as a free identifier — real, deferred, not fixed.** `identifiers(in:)` has one consumer, and an Expression formula is a single expression with no declarations. *Cost if wrong:* a bogus input socket on an Expression node, visible and harmless.
3. **Keep the unrequested public `Violation.init(kind:line:)`.** A public struct's synthesized memberwise init is internal-only, so later tasks' tests could not construct an expected `Violation` without it. *Cost if wrong:* one extra public initializer.
4. **Close the unbraced-loop-body class by refusing it**, as a fourth scope-breaker kind, rather than patching the pairing heuristic. Chasing it in the pairing logic turns a token scanner into a parser, which §24.4 rules out by name. It also retires Task 8's own admitted "one shape this misses". *Cost if wrong:* users must brace loop bodies they could leave bare — visible, immediate, one-line workaround, and no correct program becomes unwritable.
5. **Make `loopSites`' braced-opener guarantee unconditional**, not transitively true for a caller that ran `scopeBreakers` first. A guarantee resting on an uncodified call-order convention is the same "two things that must agree with nothing checking they do" pattern that caused two M7 defects. *Cost if wrong:* nil in practice.
6. **`ExpressionNode.template(for:)` belongs to Task 4, not Task 3** — the implementer was right to decline it; the dispatch note, not the brief, was the source of the ambiguity. *Cost if wrong:* one function in the wrong commit.
7. **Fix whole-token replacement via `MSLScanner.tokenise` (adding a source offset to `Token`), not by switching the regex to `wordBoundaryKind(.simple)`.** `.simple` fixes `col.rgb` but introduces the mirror bug — `a + b.a` becomes `{in.a} + {in.b}.{in.a}` — because the regex has no notion of `afterDot` while the scanner deliberately does. Verified by running the rejected route side by side. *Cost if wrong:* a two-line addition to an internal type.
8. **Bump `currentFormatVersion` 1 → 2.** M8 encodes `body` and never `graph`, so every M0–M7 build now fails to decode an M8 document — but with the gate still at 1, `VersionProbe`'s "newer version" branch never fires and the user sees "The shader could not be read". Rejected dual-writing `graph` beside `body`: real compatibility, but a redundant key forever, in a pre-1.0 single-app project. *Cost if wrong:* an M7 build refuses an M8 document it could technically have read, with a correct message.
9. **An unknown `DefinitionBody` kind must THROW, not degrade to an empty graph.** Failing the decode is recoverable — the bytes are untouched. Degrading is *un*recoverable — the user opens a newer document on an older build, sees a broken group, saves, and the code is gone. Rejected `case unknown(kind:raw:)`: most correct in isolation, but it taxes every future switch for a scenario the version gate exists to prevent. *Cost if wrong:* a hypothetical future same-version body kind fails a document that could have been partially opened; the file is intact either way.
10. **Leave `GraphClipboard.currentFormatVersion` at 1.** Bumping it would be *inert*: `paste()`'s version check runs only after a successful decode, and the nested `GroupDefinition` decode already throws on M7 bytes before the check is reached. *Cost if wrong:* a cross-version paste silently does nothing, same machine, no bytes at risk.
11. **Refuse a `.msl` output socket named `uv`/`time`/`size`/`mouse`/`in_<input>`, rather than mangling it.** A local in the function's outermost block is the *same* scope as the parameters, so it redeclares rather than shadows — verified: `redefinition of 'uv' with a different type`. Renaming the parameters takes `uv` away from the user's body; renaming the outputs is forbidden, since the contract is that the body assigns to outputs by their declared names. *Cost if wrong:* a user cannot name a socket `uv`, with a stated reason at the point of choosing it.
12. **Surface that refusal in Task 17, not Task 6.** The message belongs in `EditorModel`/`InspectorView+Groups` — Task 17's own files, and Task 17 is the task that first makes the path reachable. *Cost if wrong:* a silent refusal survives one more task, on a path nothing can hit yet.
13. **Derive `mslSystemParamNames` from `GroupCodegen.systemParams`.** They duplicated one vocabulary with no mechanical tie — the *third* instance in this milestone of the pattern §14.6 blames for two M7 defects. The failure mode is quiet in the worst way: a fifth system parameter breaks the signature goldens loudly, someone updates them, and the refusal set is left one name short. Proven by mutation: adding a fifth entry made both the signature *and* the refusal move with one edit. *Cost if wrong:* one indirection.
14. **Do not fix `MSLScanner.scopeBreakers`' scaling mid-milestone.** Measured, not guessed: ~600 ns/character; ~7.6 ms at 200 lines; fifty 200-line definitions ≈ 386 ms, re-paid on every 150 ms-debounced edit, including unreachable definitions. Real but bounded, invisible below ~10 substantial definitions, and the right fix — caching per body hash — is a clean standalone change with its own tests. *Cost if wrong:* diagnostics lag on a document full of drafts; it runs off the main actor, so frames are not dropped.
15. **Fix the legality predicate's three defects in Task 10, not in Task 11.** Task 10 owns the predicate; shipping one that refuses the generator's own output and calling it the consumer's problem inverts the dependency. A false refusal of *valid* code is also the expensive direction — it blocks work with a confidently wrong message. *Cost if wrong:* the predicate accepts a chain it should refuse, and the Metal compiler catches it one layer later.
16. **Derive accessor roots as a UNION across environments, not per-environment.** Per-environment derivation yields the empty set for `fragment` (whose spellings are not dotted call chains), which would silently disable accessor checking there. Rejected a positive rule ("any dotted call chain must be a known accessor"): it would refuse a user's own helper-struct calls. *Cost if wrong:* a typo'd accessor root stays with the Metal compiler.
17. **Make `MaterialCodegen` read the shared `materialTextureAccessor` constant.** Shipping the predicate's own accessor knowledge as a second independent spelling of a string the generator emits would recreate the §14.6 defect *inside the fix for it*. A shared constant makes disagreement impossible by construction, which beats a correspondence test that only detects it. *Cost if wrong:* a one-line indirection; the goldens catch any text change.
18. **Fix `knownAccessors`' *membership* drift too, and add the correspondence test.** Round 2's shared constant closed spelling drift for one string but not membership: `params.surface()` and `params.geometry()` were both emitted by the generator and both refused. The test runs the real `ShaderGenerator → MaterialCodegen` path, brace-matches each stage's `[[visible]]` body out of the generated text, and scans *that* — the same shape as the M7 shim correspondence tests (`f0722c0`, `646e631`). *Cost if wrong:* the predicate accepts two more chains the generator genuinely emits.
19. **Harden loops by WRAPPING the loop statement in braces, not by extending the refusal.** This differs from ruling 4 deliberately: there, correctness genuinely required parsing, so refusal was the only honest answer; here hardening *can* be made correct — the guard declaration merely needs a scope. Refusal would take away valid MSL for implementation convenience. It was also the only option contained to this task's own file. *Cost if wrong:* an extra brace pair in generated source.
20. **Close the Expression user-line mapping now rather than tracking it.** `Emitter.swift` was freed when Task 11 landed, which was the only reason it was deferred. Shipping half a feature whose other half is provably untested is worse than one more round. *Cost if wrong:* one extra fix round.
21. **Promote `CustomCodeValidation`'s dropped line number from Minor to a fix.** It held `Violation.line` and discarded it, so the task's own headline — "errors land on the user's line" — was true only for post-compile diagnostics. *Cost if wrong:* one field threaded through.
22. **Park `Emitter.swift:239`'s release-build `precondition`.** It looks like the trap withdrawn in P1, and the principle is the same, but the kind differs: P1's would have fired on input the milestone *accepts today*; this one is provably unreachable, since every substitute replacement is a single-line expression. Live vs hypothetical. *Cost if wrong:* a crash instead of a diagnostic on a path nothing can currently reach.
23. **Extract a single `UniformLayout.liveField(for:)` predicate.** This ruling was made for the *fourth* time in this milestone (after `systemParamNames`, `materialTextureAccessor`, and the `knownAccessors` correspondence test). Accepting comment-asserted agreement here after rejecting it three times would have made those rulings arbitrary. Verified mechanically: `grep "type == .float"` over `Sources/MetalNodesCore` now returns exactly one code hit. *Cost if wrong:* one indirection through a layout method.
24. **Gate the clearcoat *setter emission* on the socket being wired, not just the availability note.** Rejected the alternative (warn whenever `.clearcoat`): it documents the defect instead of fixing it and leaves every clearcoat user with a raised OS floor, and the note's advice ("remove that socket's wiring") is unactionable when there is no wiring. Semantically safe — RealityKit's default clearcoat normal is the unperturbed surface normal, exactly what the socket's `(0,0,1)` default encodes. Turned into a gate with a `-mmacosx-version-min=14.0` compile pass. *Cost if wrong:* two lines and one amended rule.
25. **Gate Exit Group *and* Undo/Redo on `canvasFocused || isEditingCode`. — REVERSED.** The reasoning was that ⌘Z inside the code editor never reached `model.undo()`. That is true, and it is *deliberate*: `EditorCommands` uses `CommandGroup(replacing: .undoRedo)`, which replaces AppKit's nil-targeted default, and a nil-targeted action is exactly what lets a focused `NSTextView`'s own undo manager win by routing down the responder chain. Once replaced by a fixed-action `Button`, an **enabled** item fires its key equivalent unconditionally and the field editor never gets a chance. The file's own pre-existing comment said so; it was misread as an oversight. The consequence of the ruling was a **live data-loss path** interacting with the same task's round-1 fix: ⌘Z while typing calls `model.undo()`, and if the popped step touches this definition's body, the watcher reseeds `draft` and drops focus, silently discarding uncommitted keystrokes. Worse than the problem it solved.
26. **Ruling 25 reversed: Undo/Redo revert to `canvasFocused` only; Exit Group keeps the widened gate.** Inside the code editor ⌘Z is field-editor *text* undo, which is what a text editor should do; document undo stays reachable after clicking out, and ⌘↑ still exits. A comment now sits *at* the gate naming the `CommandGroup(replacing:)` mechanism and tracing the data-loss path — this reasoning has been got wrong twice, and a report will not stop the next person "fixing" it again. *Cost if wrong:* ⌘Z inside the editor does the wrong one of two undos; the comment is the guard.

### 15.3 In-app checklist — NOT RUN

**This is owed to a human. Nothing in it was verified.** The machine's screen was locked (`CGSSessionScreenIsLocked=1`) for every UI task in this milestone and for Task 19; an agent may not unlock it, and did not attempt to. Task 17's fix round 1 is the *only* round in M8 with any live app verification at all, and it predates the `EditorCommands` gate that round 3 settled.

The list below — **41 items** — is assembled from five task reports and the ledger, deduplicated, in the order a person should walk it. **It is self-contained — no other file needs reading.** Nothing here is a claim; every line is a question.

#### A. The M8 feature checklist (13 items — plan Task 19 Step 3)

1. **Expression, happy path.** New document → add an Expression node → type `a * b + 0.5`. **Correct:** two sockets appear, named `a` and `b`; wiring two floats in and the output to the Fragment Output makes the preview update, and the generated-code panel shows the formula inlined (no function call). *(Task 19)*
2. **Expression, error path.** Change the formula to `a * qq`. **Correct:** a red message appears under the field naming `qq`, and the preview keeps its **last good frame** rather than going black. *(Task 19)*
3. **Expression, reshape.** Change it back to `a * b`. **Correct:** the `qq` socket disappears, the wire that fed it is gone, and ⌘Z brings **both** back. *(Task 19)*
4. **Custom Code, creation.** ⌃⌘N. **Correct:** a node appears with one input and one output, and the preview still renders. *(Task 19)*
5. **Custom Code, editing.** Dive in. **Correct:** the canvas is replaced by the code editor showing the starter body; changing line 3 to something with a deliberate typo and clicking out makes the list beneath say **3** and name the identifier. *(Task 19)*
6. **Custom Code, sockets.** With the definition open, add an output in the inspector, assign to it in the code, wire it up on the parent canvas. **Correct:** it carries a value. *(Task 19)*
7. **Custom Code, instances.** Place a second instance from the palette; edit the definition once. **Correct:** both instances change, and the generated code contains the function **exactly once**. *(Task 19)*
8. **Loop cap.** Write `for (int i = 0; i < 100000000; ++i) { out += a * 0.0000001; }`. **Correct:** the app does not hang; the editor still shows the loop **exactly as typed**; the generated-code panel shows the capped form. *(Task 19)*
9. **Scope breaker.** Write `out = a; }`. **Correct:** the guard refuses it with a message naming the problem, rather than emitting broken MSL. *(Task 19)*
10. **Clearcoat.** RealityKit target, lighting model Clearcoat, wire Clearcoat to `0.8`. **Correct:** the preview gains a visible sheen, and the caption about the approximation is present. *(Task 19)*
11. **Custom attribute.** Wire a colour into Custom Attribute and read it back through the Custom Attribute node into Base Color. **Correct:** the preview shows the colour, interpolated across the mesh. *(Task 19)*
12. **Live parameters.** Mark two floats live. **Correct:** the settings section lists them as `.x` and `.y`; on export the header names them and the `.metal` reads `custom_parameter()`. *(Task 19)*
13. **Migration — the single most load-bearing line in this list.** Open **any document saved by an M6- or M7-era build** and confirm it opens, renders, and its generated MSL is unchanged from before this milestone. (If you still have the `Test.mnshader` you saved during M5/M6, use that; it is a local file, not in the repo, so do not go looking for it.) **If you have no such document, make one — this is the recipe Tasks 5 and 14 actually used:**
    ```
    git worktree add --detach /tmp/mn-pre-m8 ddc6527
    cd /tmp/mn-pre-m8 && open MetalNodes.xcodeproj    # build and run this older app
    # save two or three documents from it: one plain, one with a group definition, one textured
    git worktree remove --force /tmp/mn-pre-m8
    ```
    Then open those files in the M8 build. **Correct:** each opens with **zero** validation errors, renders, and its generated MSL is byte-identical to what the old build produced. **Also check the other direction:** save one of them from M8, then try to open it in that older build — it must be refused with *"saved by a newer version of MetalNodes"*, **not** *"The shader could not be read"*. That message is the entire point of ruling 8's `currentFormatVersion` 1 → 2 bump, and it has never been seen by a person. *(Task 19; §15.5 item 1 explains why this stands in for a gate that does not exist)*

#### B. Checks the code editor's own review left owed (Task 17 — 7 items)

14. **⌘Z mid-typing, inside the editor.** **Correct:** the *text* undoes locally; focus does **not** drop; uncommitted keystrokes do **not** vanish. This is ruling 26's whole subject and has never been observed. *(Task 17, fix round 3)*
15. **⌘Z after clicking out.** **Correct:** the *document* undo fires — the body edit reverts and the problems list updates. *(Task 17, fix round 3)*
16. **⌘↑ inside the code editor exits it.** The C2 fix silently removed the only keyboard exit; the re-widened Exit Group gate is supposed to have restored it, and that is structural reasoning, not an observation. *(Task 17, fix round 2)*
17. **Error persistence after undo.** Type lines ending `out = zz;`, click away, confirm the error appears. Click back in, ⌘Z. **Correct:** the text visibly reverts, and after clicking elsewhere the error does **not** come back. Repeat with File ▸ Revert To Saved. *(Task 17, fix round 2)*
18. **Continuous typing under a live recompile.** Type for ~5 s without pause while recompiles fire. **Correct:** no lost characters, no focus drop. Never attempted in any round — scripted keystrokes do not reproduce real typing timing. *(Task 17, fix round 2)*
19. **⌃⌘N after visiting the code editor, three times.** Then ⌘⇧N and a palette double-click. **Correct:** a node appears every time. This is the C2 latch — before the fix, every `requestCanvas`-routed command was dead for the rest of the session. *(Task 17, fix round 2)*
20. **Definition A → B → A with unsaved edits in each.** **Correct:** each definition's own body is preserved; B's text never lands in A. Structurally settled by a headless SwiftUI probe (handlers fire in declared order); not seen. *(Task 17, fix round 2)*

#### C. Checks the live-parameter and formula UI left owed (Tasks 15, 18 — 16 items)

21. **The Live toggle's appearance next to a float param**, under a RealityKit document. **Correct:** the checkbox reads clearly at `.caption` size; the `custom_parameter().x` label wraps or truncates acceptably; toggling flips it visually and immediately. *(Task 18)*
22. **Refusing the fifth mark.** With four params already live, tap a fifth "Live" checkbox. **Correct:** the checkbox reverts. **This is the one control in M8 that can visibly lie**, and it cannot be settled from source: the binding's `set:` ignores its argument and calls `toggleLiveParameter`, which on refusal shows a notice and returns `false` *without* touching `document` — and `InspectorView` never reads `model.notice`, so nothing invalidates the body. Whether `Toggle` reconciles get-after-set internally is private AppKit-bridging behaviour. Watch whether it snaps back, lags, or **sticks**. *(Task 18)*
23. **The document-settings "Live parameters" list.** **Correct:** correct ordering, correct component letters, correct node/param labels; "Unmark" removes the right row (including with a hand-edited duplicate path, now that rows key on offset); the reachability warning appears and disappears as a param's wiring to the terminal changes. *(Task 18)*
24. **The refusal notice text** — "A material exposes four live values; unmark one first" — appears in the preview pane's diagnostics strip for ~3 s and clears itself. *(Task 18)*
25. **The clearcoat caption** renders under the segmented Lighting picker **only** when Clearcoat is selected, and reads sensibly alongside the existing Cook-Torrance caption. *(Task 18, carried from Task 13)*
26. **iPadOS Live toggle.** The `#if os(macOS)` guard means no explicit `.toggleStyle` there. **Correct:** the platform default (likely a switch) does not look out of place at `.caption` next to a slider row, including on unwired-input rows. *(Task 18)*
27. **Non-RealityKit regression.** On a fragment or stitchable document: **no** Live toggle and **no** live-parameters section appear anywhere, including on the newly-added unwired-input rows. Verified only by reading the `s.target == .realityKit` gate. *(Task 18)*
28. **The formula field's layout** at 190 pt node width. **Correct:** the 46 pt label and the field fit on one line without truncating either, and `a + b * sin(t)` is legible. *(Task 15)*
29. **One undo step per formula edit.** Click in, type, click away (or Return). **Correct:** Edit ▸ Undo shows exactly **one** step, not the two some focus sequences could produce. *(Task 15)*
30. **⌘Z *inside* the formula field, mid-edit.** With the cursor in an Expression node's formula `TextField`, press ⌘Z. **Correct:** the field's own **native text** undo fires — not the document undo. This is a *different control* from the code editor's `TextEditor` (items 14–15) and needs its own look; ruling 26's mechanism (`CommandGroup(replacing: .undoRedo)` replacing AppKit's nil-targeted default) governs both, and it has been got wrong twice. *(Task 15, owed item 2)*
31. **Duplicate diagnostics render as two rows.** Produce two byte-identical errors (e.g. `return a; return b;` in a Custom MSL body). **Correct:** two rows, not one — `ForEach(id: \.self)` over a `Hashable` `Diagnostic` collides, and *being* `Hashable` is what makes the collision possible. *(Task 15, review finding)*
32. **The formula field's row does not overlap the row below it.** Select an Expression node with a formula and look at the node body on the canvas: the single-line formula row must sit cleanly in its one allotted row without the next parameter row riding over it. This is the only in-app check of Task 15's IMPORTANT 3 — `estimatedSize` was **under**-stating node height for a single-line `.text` param, which is the worse direction for hit-testing. *(Task 15, IMPORTANT 3)*
33. **Formula error text legibility.** The red/yellow `Label` at `.caption2` against the Dracula surface, with a long compiler message. **Correct:** legible, and it does not overflow the inspector's width. *(Task 15)*
34. **Node reshape has no visual glitch.** Editing a formula and committing produces a visibly different node — new/removed sockets, resized — cleanly. Confirmed only at the data level. *(Task 15)*
35. **Socket anchors on a multiline text param.** **You need a Custom Code node for this, not an Expression node** — the Expression's formula field is single-line, and the 44 pt disagreement only manifests for a *multiline* text param, which Task 17's code editor is the first thing in the app to declare. Place a Custom Code node, wire something into an input, zoom out until it is culled, pan back. **Correct:** the wire lands on the socket dot, not ~44 pt above or below it. *(Task 15, IMPORTANT 1)*
36. **iPad autocorrect/autocapitalisation suppression** for a formula like `float3(1,0,0)`. `.autocorrectionDisabled()` and `.textInputAutocapitalization(.never)` are the right calls; only a device confirms iPadOS honours them. **Smart quotes and smart dashes are NOT suppressed** — no SwiftUI API exists (see §15.5); confirm whether iPadOS actually substitutes inside a monospaced field in practice. *(Task 15)*

#### D. Still owed from M6 — and unclosed by M7 and M8 (handoff §13, §14.4 — 5 items)

37. **macOS: drag an image file from Finder onto the canvas.** **Correct:** it becomes a Texture Sample node with that image assigned. Not deliverable by automation.
38. **macOS: drag a node from the palette onto the canvas.** **Correct:** it lands where it was dropped. XCUITest cannot start an AppKit `NSDraggingSession` (M6 R13).
39. **iPad with a hardware keyboard — M6 check 14**, the shortcut sweep. Press each and watch: **⌘Z / ⇧⌘Z** step the document undo stack; **⌘C then ⌘V** pastes at the *viewport centre*, not at the original position; **⌘A** selects every node; **⌫** deletes the selection; **arrow keys** nudge the selection by one grid step (⇧-arrow by ten); **⇧A** opens the node chooser; **Escape** cancels an in-progress wire drag or dismisses the chooser. Then focus a parameter field and press **⌫** — **correct:** it deletes a character in the field and does **not** delete the node. That last one is the whole reason this check exists (M6 R11: whether a disabled `Commands` entry yields its shortcut to a focused `TextField` on iPadOS is settled by this check, not by code). The Simulator cannot substitute — it drops synthetic keys in capture mode and routes ⌘ keys to Simulator.app.
40. **iPad: two-finger pan and pinch-zoom on the canvas**, in all three modes, pinching about the fingers with the LOD swap. Not drivable from a mouse.
41. **iPad: Slide Over / Split View at compact width.** **Correct:** the inspector collapses and nothing becomes unreachable. Cannot be produced in the Simulator from an agent session.

### 15.4 Defects the reviews caught that the tests did not

The most useful section of §14, kept. Each of these was invisible to a fully green suite.

- **A swizzle in an Expression formula silently produced undefined MSL — the closest thing in this milestone to a shipped, silently broken feature.** Identifier substitution used a `\bcol\b`-shaped regex, and `\b` in Swift Regex is a **Unicode (UAX #29)** word boundary where `.` between two letters is *not* a break — so `\bcol\b` never matches inside `col.rgb` **at all**. Traced end to end: a formula of `col.rgb * k` allocated a uniform slot, emitted `v0 = col.rgb * 2.0;` with `col` undefined, and failed at Metal compile **with no diagnostic pointing at the node**. The rejected fix (`wordBoundaryKind(.simple)`) introduces the mirror bug — `a + b.a` becomes `{in.a} + {in.b}.{in.a}` — which is why ruling 7 sent it through `MSLScanner.tokenise` instead.
- **A hardener that emitted `break` outside the loop.** The plan's prose said the guard is "inserted as the first statement of the loop body"; its reference *code* appended a whole new line **after** the loop's source line — which for the common one-physical-line shape `while (a) { x += 1; }` puts the `break` outside the braces. Compiling a 14-shape matrix: 8 of 14 naive outputs fail with `'break' statement not in loop or switch statement`, **including the plan's own GPU test body**. Worse, for a loop whose `{` is on the next line, the naive version inserts the check *between header and brace* — which **compiles clean** and then runs the body exactly once, unconditionally, after an empty loop. Silent wrong pixels, no diagnostic.
- **An availability macro that made an unwired socket a hard build error.** `set_clearcoat_normal` carries `availability(macos, introduced=15.0, strict)`, and `strict` is an error, not a warning. Emitting it unconditionally under `.clearcoat` meant that picking the Clearcoat lighting model and never touching the Clearcoat Normal socket produced a `.metal` that **fails to compile in the user's own Xcode project** at `-mmacosx-version-min=14.0` — with the export saying nothing, and the availability note (gated on the socket being *wired*) never firing. When the note did fire, its advice — "remove that socket's wiring" — was unactionable, because there was no wiring.
- **A crash on opening a five-live-parameter document.** A Swift **exclusivity-of-access** runtime trap while pruning dangling live parameters: `document.settings.liveParameters` was mutated while a closure read `document` for lookups. A crash class, not a logic bug, and no test reached it.
- **⌘Z silently reverting itself in the code editor.** `draft` was seeded only on appear, so document undo fired invisibly and then the focus-loss commit wrote the **stale draft back**. Found by building and driving the real app; no test in this package renders a SwiftUI view.
- **A canvas command dead for the rest of the session.** The canvas swap latched `canvasRequest`: `canvasHasFocus` was never cleared on unmount, so after one visit to the code editor **every** `requestCanvas`-routed command — ⌃⌘N, ⌘⇧N, zoom, palette double-click, iPad ⌘V — stopped working until an unrelated command happened to clear the latch.
- **The fix for the dead canvas command silently removed the only keyboard exit.** Clearing `canvasHasFocus` on unmount is right in principle, but Exit Group was `.disabled(!canvasFocused)` and had been surviving on the very latch that was the bug — so ⌘↑ stopped working inside the code editor, leaving only the breadcrumb. An undisclosed keyboard regression shipped *inside* a fix, found by the next round's review rather than by any test.
- **A `.texture`-typed definition output emits `texture2d<float> out = 0.0;`** — invalid MSL. Still live: it is unreachable today only because the socket-type picker does not offer `.texture`, which is a UI accident rather than a guard. Comparable unreachable items are carried in §15.5, so it is named here too rather than quietly dropped.
- **A commit message overclaimed a fix as "collision-safe".** `resultVar = "<outStruct>_result"` is collision-*unlikely*: an output named exactly that reproduces the original redeclaration bug. The code was fine; the record was not, and a record that overclaims is how the next person stops checking.
- **Two row-counting functions, one updated.** `bodyRows` and `socketAnchor` disagreed by **44 pt** for a multiline text param (86.0 measured against an implied 130.0), so a wire would land well off its socket dot; and a single-line `.text` param drew *taller* than its one allotted row, making `estimatedSize` **under**-state node height — the worse direction for hit-testing. Both found by driving the app; the row math is a model this package can test, the rendered height is not, so the fix made the two agree **by construction** (the field now uses the same `HStack` convention as float/float2/float3) rather than by keeping a second guess in sync.
- **A definition's output named `uv` was a hard Metal error, and the first report dismissed it.** The claim was that C++ shadowing makes it legal. It does not: a local in the function's outermost block is the *same* scope as the parameters. Verified: `redefinition of 'uv' with a different type: 'float' vs 'float2'`.
- **The plan's own starter body did not compile.** `out = a * 2.0;` — `use of undeclared identifier 'a'`, because a `.msl` definition's inputs are in scope only as `in_<name>`. The validator reports **zero** errors for it; only a real `xcrun metal` compile catches it. This exact defect appeared **three times** in this plan (the Task 8 GPU test body, the Task 16 starter body, and the Task 19 sample body).
- **A brace-less `do` whose single statement is itself a loop** (`do while (x) { y += 1.0; } while (a);`) swallowed the inner loop entirely — it escaped hardening (unguarded) *and* produced a spurious site at the closing `while (a)`.
- **Hardening turned valid accepted code into a compile error** where a loop sat in an unbraced `if`/`else`/`case` slot: the spliced guard declaration stole the statement slot, yielding `use of undeclared identifier 'mn_loopGuard0'` — naming a symbol that appears nowhere the user wrote.
- **The legality predicate refused the generator's own output.** `params.geometry()` and `params.surface()` are both emitted by `MaterialCodegen` and both were `.missing`; `geo.vertex_id()` had **no** legal spelling at all, because it is stored as the expression `int(geo.vertex_id())`; and `.variants` **failed open** when the chosen enum case was nil, making a node legal that reads a missing key in every variant.
- **`Emitter` dropped `readable` when handing `sys` to a `.custom` body** (`mapValues(\.spelling)`). A body reading `ctx.sys["mouse"]` under RealityKit would have silently received the fill-only literal `float2(0.0, 0.0)` **as data**, while `canEmit` said `.allowed` — a silent wrong value, not the crash the plan assumed.
- **CRLF collapsed the user-line mapping.** Swift treats `\r\n` as one grapheme, so a Windows-pasted body was seen as a *single* line and every diagnostic reported line 0. Latent for emitted MSL; fatal for the error mapping that is half of this milestone's point.
- **`GraphValidator` applied pseudo-node rules to a `.msl` body**, and `ShaderGenerator.bake(_:)` rebuilds an `EmitEnvironment` **without** `knownAccessors`, silently defaulting to `[]` — the same "lose a field on rebuild" shape as the `mapValues` bug above.
- **A new `float4` socket renumbered every uniform slot.** The report claimed "additive-only, no renumbering"; `UniformLayoutBuilder.build` stable-sorts by **alignment descending**, so the new `float4` lands in the float4 group: `p4` changes type, `u.p8 → u.p12`, `u.p5 → u.p7`. Textual only — nothing binds by slot name — but the record would have been false.

**And the reversal.** Ruling 25 was itself a defect the review caught: a fix that would have opened a live data-loss path. See §15.2 rulings 25–26.

### 15.5 M9 starting list

**Gates that do not exist.**

1. **There is no automated backward-compatibility gate, and there never has been.** Confirmed at Task 14: no document fixture exists anywhere in the repo, and `Package.swift` declares no `resources:` on any test target, so one could not be loaded even if written. Pre-M8 documents were verified **by hand** twice — at Task 5 and Task 14, by building detached worktrees at the old commits, writing documents with the old encoder, and decoding them with the new one (all opened; MSL byte-identical by FNV-1a hash). Neither run committed a fixture or a test. **Tasks 6 through 17 had no gate at all**, and M8 is the first milestone with a genuinely breaking format change (`currentFormatVersion` 1 → 2). Commit a fixture corpus and a decode test; it is the highest-value single item on this list.
2. **Checklist item 13 (migration) is the only thing standing in for that gate right now** — and it has not been run. It was rewritten in this round to be executable by someone who has never worked on this project: it no longer points at a `Test.mnshader` that exists only on one person's disk, and it carries the detached-worktree recipe Tasks 5 and 14 actually used, plus the reverse direction (an M8 document opened by an M7 build must say *"saved by a newer version"*, which no person has ever seen).
3. Consider `MTL_DEBUG_LAYER=1` on CI's test step (carried unclosed from §14.6 item 8).

**Known behaviour changes M8 shipped that a user may report as bugs.**

4. **An M7-era document using aspect-mode UV under `.realityKit` now fails validation on open**, blocking preview *and* export, with a diagnostic that never mentions the fix (switch the mode picker to Normalized). This **reverses** a documented M7 decision — spec lines 1565 and 1649 justified the fill value as making `aspect` "degenerate to centred UV rather than nonsense". M8 found §23.10 internally inconsistent and picked the refusal side (§24.10). Either add the actionable hint to the diagnostic or revisit the reversal.
5. **Preview/export divergence when a terminal geometry parameter is set but not wired.** The preview carries the edited value; the export's `hasGeometryWork` counts only non-terminal body lines, so no geometry function is emitted and the surface stage reads RealityKit's zero — while the exported header lists the value as baked. The mechanism predates M8 (`positionOffset` always had it), but Task 14 extended it to a channel where the symptom is a **wrong colour** rather than a silent geometry no-op. Fix candidates: have `hasGeometryWork` also fire when a geometry socket's baked value differs from its declared default, or add a validation warning.
6. **`MSLScanner.tokenise` still has the CRLF defect.** `LoopHardening.hardened` normalises on entry, but the scanner does not, so `Violation.line` is **0** for every violation in a Windows-pasted body — and `CustomCodeValidation` works around it with its own local normalisation. Fix it at the source.

**What M8 deferred by design.**

7. The code editor's **gutter decoration** (error markers in the margin).
8. **A second open definition at once** — the editor holds one.
9. **`#include` of user files** — refused outright today.
10. **Smart quote / smart dash substitution cannot be suppressed** in a SwiftUI `TextField`: no modifier exists on either platform (verified against both `SwiftUI.swiftinterface` files). It is an `NSTextView`/`UITextView` property, so suppressing it needs a representable. Real limitation, not a bug.

**Performance, measured not guessed.**

11. **Cache `MSLScanner.scopeBreakers` per body hash.** ~600 ns/character over three linear passes plus grapheme segmentation: ~1.85 ms at 50 lines, ~7.6 ms at 200, ~39 ms at 1000. Ten 200-line definitions ≈ 76 ms per recompile; fifty ≈ 386 ms — re-paid on every 150 ms-debounced edit *anywhere* in the document, and `CustomCodeValidation` scans every **authored** definition, not just reachable ones. Off the main actor, so it delays diagnostics rather than dropping frames.
12. `GraphValidator` rescans every definition body on each debounced recompile, not just the edited one.

**Duplication that will drift.**

13. **`LoopHardening` duplicates ~60 lines of `MSLScanner.loopOpeners`** (`loopBraceSites`/`bracedHeaderBrace`), because offsets were needed while a concurrent task owned the scanner. That constraint is gone, and the duplication **grew** with the brace-wrapping fix (do/while close indices, case-boundary lookahead). Fold `keywordStart`/`braceEnd`/`closeIndex` into the scanner's own opener struct.
14. `stripComments` and `tokenise` each reimplement `//`-and-`/* */` skipping — equivalent today, verified, duplicated. Pre-existing.
15. The `xcrun metal --version` probe plus `Process`/`Pipe` boilerplate is copy-pasted across **seven** test files (Task 19 added the seventh). A shared `metalCompiles(_:)` helper removes ~30 lines per site.

**Smaller deferred items, per task.**

- **T2:** `float a, b;` binds only `a`, leaking `b` as a free identifier (ruling 2 — unreachable from an Expression formula).
- **T3:** `LibraryM3Tests.everyNodeGeneratesAsAOneNodeGraph` gives Expression **zero** coverage — the registry def has no outputs, so the sweep never wires it. `ExpressionEmissionTests` is the only end-to-end coverage of Expression emission.
- **T4:** `MSLScanner.swift:82-83`'s doc comment says "bound" where it means "free"; no test pins repeated-occurrence substitution (`a * a`), verified working but unasserted.
- **T5:** `GraphClipboard.currentFormatVersion` left at 1 (ruling 10 — inert either way; revisit together with a paste-failed notice, which does not exist).
- **T6:** `mslNameCollides`' `.input` branch is the only branch with no test; the `.msl` branch's `layer` handling is dead code (were it live, an output named `layer`, `position` or exactly `<outStruct>` would collide unguarded); `GroupCodegen.systemParamNames` is `internal`.
- **T8:** `cuts.sorted(by:)`'s tie-break is unstable where two cuts share a column (both orderings emit valid MSL, verified byte-identical across runs — unspecified rather than wrong); `CustomCodeCompileTests` proves "compiles and links", not §24.9's "returns" — no pipeline is dispatched and nothing is read back.
- **T9:** `Emitter.swift:239`'s `precondition` traps in **release** builds too (ruling 22 — provably unreachable today; a `guard … else { .generated }` softening is the fix); `LoopHardening.harden(_:)` has no production caller; `CustomCodeValidation` scans the **untrimmed** formula while codegen maps the **trimmed** one, so a formula with leading newlines would report line numbers one path apart (unreachable while the field is `.text(multiline: false)`).
- **T10:** `EmitEnvironment.swift:230` uses `table[c]!` — safe, but iterating pairs removes the force-unwrap.
- **T11:** `ShaderGenerator.bake(_:)` rebuilds an `EmitEnvironment` without `knownAccessors`, silently defaulting to `[]`.
- **T14:** the `v0` SSA-name assertions are correctness-fragile (`varCounter` resets per stage and the fixture's colour node happens to land on `v0`); `MaterialCompileTests.swift:119` still asserts only `shader.source.contains("o.customAttribute =")` — the call-shape-only pattern that Task 14's own Critical flagged.

**Build configuration.**

16. `IPHONEOS_DEPLOYMENT_TARGET` is **27.0** in both `MetalNodesKit/Package.swift` and the project, while Xcode Cloud's Xcode 26.6 supports up to 26.5.99. The iOS build succeeds with five warnings on that toolchain. Pre-existing since `2d02436`; adopt the iOS 27 SDK properly or lower the floor, but do it deliberately.

### 15.6 The plan's own defect rate — the transferable lesson

This is a section the handoff has never had, and it is the most portable thing M8 produced.

**Twenty defects were found in this plan's own briefs** — sixteen through Task 18, four more in Task 19's own brief. The count is reconciled from the task reports, not taken from the ledger: the ledger runs *three* overlapping counters ("broken plan items", "vacuous plan tests", "brief/instruction defects"), its highest single figure is "the 14th brief/instruction defect" at Task 15, and it never records a 15th. Treat twenty as a floor, not a total. None of these is a typo — each one, followed literally, would have shipped broken code or a test that could never pass:

| # | Task | The brief said | Reality |
|---|---|---|---|
| 1 | 2 | three under-approximations in the reference scanner | `/* c */ #include <x>` passed the scan; comments are stripped in phase 3, directives recognised in phase 4 |
| 2 | 4 | Step 3's emission path was sufficient | `Emitter` read socket decls from the **registry** def, empty by design for Expression, so the output variable was never declared and unwired identifiers emitted `/* ?in.x */` |
| 3 | 4 | `\bcol\b` matches `col` in `col.rgb` | `\b` is a **Unicode** word boundary and `.` between letters does not break there — it never matches at all |
| 4 | 5 | three test assertions about the wire format | `EntityID` encodes as a bare UUID string, `Graph` writes arrays, and delete has never cascaded |
| 5 | 6 | the starter body names the definition's output `out` | the shared epilogue already declares a local `out` — a Metal redeclaration error for the most obvious possible body |
| 6 | 7 | `Violation.Kind` has three cases | ruling 4 had already added a fourth |
| 7 | 8 | prose: "inserted as the first statement of the loop body" | its own reference **code** appended a line after the loop — `break` outside the braces, 8 of 14 shapes failing |
| 8 | 8 | the GPU test body reads `a` | a `.msl` definition's inputs are `in_a` |
| 9 | 11 | Step 5: use `environment(for: target)` | a `.msl` definition emits as a **group function**, so `params`/`geo` are out of scope under every target — the brief would have declared `params.geometry().normal()` legal and shipped a `.metal` that cannot compile |
| 10 | 12 | `thePreviewIsUnchangedByMarkingAParameterLive` | compared two **structurally different graphs** (1 vs 2 wired nodes) — it would have failed regardless of correctness |
| 11 | 13 | the `liveSurfaceSockets` snippet emits the setter unconditionally | the availability note is gated on the socket being wired — the two disagreed, and `strict` availability made it a build error |
| 12 | 16 | the starter body `out = a * 2.0;` | `use of undeclared identifier 'a'` |
| 13 | 16 | `aNewDefinitionValidatesClean` | a bare `ShaderDocument()` always lacks a Fragment Output node — it could **never** pass |
| 14 | 17 | `EditorModel.diagnostics` is `internal(set)` | it was `private(set)` |
| 15 | 17 | `DefinitionPane` has an add-socket button | it builds an `AddSocketRow` |
| 16 | 15 | call `.smartQuotesDisabled()` and `.smartDashesDisabled()` | **these SwiftUI modifiers do not exist** on either platform — the implementer grepped both `SwiftUI.swiftinterface` files, found zero matches, and documented the gap rather than fabricating a call |
| 17 | 19 | modify `Tests/MetalNodesCoreTests/SampleDocumentTests.swift` | no such file exists; the sample assertions live in `LibraryM3Tests` |
| 18 | 19 | the sample's Custom MSL body `out = c * float3(…)` | `use of undeclared identifier 'c'` — the **third** appearance of defect #8/#12 in one plan |
| 19 | 19 | the sample "generates for `.realityKit` **and** `.fragment`" | impossible for one document: validation requires the target's own terminal and refuses the other. Asserted instead of the sample's *content*, re-terminated on a Fragment Output |
| 20 | 19 | add `customCodeSample()` to `SampleDocuments` as a `public static func` | `SampleDocuments` is **not a type** — the samples are members of `public extension ShaderDocument`, declared `static func`. The snippet also built its definition with a constructor whose sibling factory (`.make(name:)`) seeds a `.graph` body with pseudo-nodes, which a `.msl` definition must not have |

Three of the twenty (#1, #7, #9) would have shipped **generated** Metal that does not compile — output no user typed. Two more (#12, #18) are Metal that does not compile as **default text the user is handed**: the starter body every new Custom Code node is born with, and this milestone's own sample document. That is a different failure — visible on the first edit rather than buried in codegen — but it is still five of twenty that do not build. Two (#10, #13) were tests that could never pass. One (#16) instructed the implementer to call an API that does not exist — and the right response, which the implementer gave, was to grep the platform interface and report the gap. **#3 came closest of any to shipping a silently broken feature**: a `\b`-bounded regex never matches `col` in `col.rgb`, so a formula of `col.rgb * k` allocated a uniform slot, emitted `v0 = col.rgb * 2.0;` with `col` undefined, and failed at Metal compile with **no diagnostic pointing at the node** (see §15.4).

**Eight tests shipped passing regardless of correctness**, each caught only by *mutation* — deliberately breaking the production code and checking that something fails:

| Task | The test | The mutation that left it green |
|---|---|---|
| 4 | `twoExpressionsEmitTwoStatements` | its first Expression was orphaned, so `TopoSort`'s dead-code elimination dropped it before codegen ran |
| 6 | the whole redeclaration fix | reverting **the entire fix** left 409/409 green |
| 10 | `.variants` legality | fail-open on a nil enum case, untested in **either** direction |
| 12 | `thePreviewIsUnchangedByMarkingAParameterLive` | (see #10 above — it compared different graphs) |
| 13 | `thePreviewCarriesASecondLobeUnderClearcoat` | greps the substring `mn_clearcoat`, so it catches a missing **call** but not a missing **definition** |
| 14 | both halves of the custom-attribute channel | setting the export setter *and* the preview write to `float4(0.0)` each left 875/875 passing — every wired custom attribute would export and preview **black** |
| 15 | the socket-pruning scope | dropping `$0.key.node != id` — which deletes essentially every wire in the document — left all six new tests green, because the fixture had exactly one wire |
| 15 / 17 | `bodyRows`; `.setDefinitionBody`'s change classification | `bodyRows` was entirely untested; changing `.topology` to `.cosmetic` (which would mean editing a body **never recompiles**) left 858/858 passing |

**The practice that caught them.** Every review in this milestone was required to *run* something rather than read it: revert the fix and watch the suite; inject a fake and watch it pass unnoticed; compile the generated MSL with real `xcrun metal`; build a detached worktree at the old commit and diff real bytes. Concretely, that is:

1. **Mutate before believing.** A test that does not fail against deliberately broken code is not evidence. The reviewer that added a fifth entry to `systemParamNames` and confirmed *both* the emitted signature and the socket refusal moved with one edit is the pattern; the reviewer that ran the test unmodified and reported "still passes" as coverage is the anti-pattern (Task 14, I1).
2. **Compile the output, do not grep it.** Six of these defects produce syntactically plausible text. `xcrun metal` found them; substring assertions did not.
3. **Prefer derivation to a correspondence test, and a correspondence test to a comment.** Four separate rulings in this milestone (13, 17, 18, 23) reduce to the same finding: two lists that must agree with nothing checking that they do is *the* recurring defect shape in this codebase, named in §14.6 as the shared cause of two M7 defects. Deriving one from the other makes disagreement impossible; a correspondence test only makes it detectable; a comment makes it nothing.
4. **Report what was not run.** Task 17's reviewer found the screen locked, said so three times in three rounds rather than reasoning and calling it verified, and that honesty is why §15.3 above is a usable list instead of a false one.
