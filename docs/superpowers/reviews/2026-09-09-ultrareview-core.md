# MetalNodesCore — deep review

Scope: `MetalNodesKit/Sources/MetalNodesCore` (all 60 files read in full), cross-checked against
`Tests/MetalNodesCoreTests` and, where reachability mattered, the UI call sites in `MetalNodesUI`.
Read-only. Claims marked **confirmed** were reproduced with a scratch SwiftPM executable that links
`MetalNodesCore` (`scratchpad/ultrareview/probe`, not in the repo) and, for MSL questions, with
`xcrun -sdk macosx metal`. Nothing below requires moving the document format off version 2 or
changing any `FormatCorpusTests` golden; every suggested fix is either decode-side tolerance,
validation, or a scanner/emit change that only affects inputs that do not compile today.

All paths are relative to `MetalNodesKit/Sources/MetalNodesCore/`.

---

## Findings (most severe first)

### 1. Opening a document with a duplicated node/edge/sticky/frame/definition id crashes the app instead of failing with `PackageError.undecodable`
- **Severity:** high · **Category:** bug · **Confidence:** confirmed
- **Where:** `Graph.swift:126-129`, `ShaderDocument.swift:314`
- `Graph.init(from:)` and `ShaderDocument.init(from:)` build their dictionaries with
  `Dictionary(uniqueKeysWithValues:)`, which **traps** on a repeated key. `ShaderPackage.init(fileWrapper:)`
  (`Persistence/ShaderPackage.swift:64-68`) wraps the decode in `do/catch` expecting a thrown error, but a
  trap never reaches the `catch`. Duplicate node ids or two edges into the same input are exactly what a
  hand-resolved git merge of `document.json`, a script, or a partially corrupted save produces. The same
  decoder runs for clipboard payloads (`GraphClipboard.definitions`), so a crafted pasteboard also crashes.
- **Repro (probe, `dupnodes` / `dupedges` modes):** decoding
  `{"nodes":[{"id":"X",…},{"id":"X",…}],"edges":[]}` →
  `Fatal error: Duplicate values for key: 'X'`; two edges with the same `to` →
  `Fatal error: Duplicate values for key: 'SocketRef(node: …, socket: "x")'`.
- Contrast: `DocumentSettings.assets` already decodes with `uniquingKeysWith: { $1 }` (`ShaderDocument.swift:164`) —
  the two are inconsistent.
- **Fix:** decode tolerantly and *report*, never trap. Either last-wins (mirrors `assets`) or, better, throw
  `DecodingError.dataCorrupted` so the user sees "The shader could not be read: duplicate node id …":
  ```swift
  let list = try c.decode([NodeInstance].self, forKey: .nodes)
  nodes = try Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in
      throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [Keys.nodes],
                                              debugDescription: "duplicate node id \(a.id)"))
  })
  ```
  (same for `inputs`, `stickies`, `frames`, and `definitions`). Encoding is unchanged, so the corpus goldens
  do not move.

### 2. The Expression node turns common MSL builtins and constants into sockets, so ordinary formulas emit MSL that cannot compile
- **Severity:** high · **Category:** bug · **Confidence:** confirmed
- **Where:** `Codegen/MSLScanner.swift:41-58` (`reservedNames`), consumed by `Library/Builtin/ExpressionNode.swift:32-41`
- Spec §24.2 says identifiers are "filtered against the MSL keyword and builtin-function lists so `sin`,
  `float3` and `length` are not mistaken for sockets". The list is hand-picked and misses a lot of what a
  shader author types in a one-liner: `fmod`, `fmin`, `fmax`, `fabs`, `fwidth`, `dfdx`, `dfdy`, `any`,
  `all`, `powr`, `exp10`, `log10`, `rint`, `sincos`, `mad`, `transpose`, `determinant`, `as_type`, the
  constants `M_PI_F`, `M_E_F`, `INFINITY`, `NAN`, `packed_float3`, and every `mn_*` stdlib helper the
  app itself ships (`mn_hash21`, `mn_valueNoise`, …). Each becomes a `.value(.float(0))` input socket with
  its own generic, is requested as a uniform, and the formula is rewritten so the *call* is replaced by a
  uniform read.
- **Repro (probe):** formula `fmod(a, 2.0)` → shape inputs `["fmod", "a"]`; generated statement
  `v0 = u.p0(u.p1, 2.0);` — a compile error blamed on the user's line. `a * M_PI_F` → socket `M_PI_F`.
  `fwidth(x)` → socket `fwidth`. The user also sees a bogus "Fmod" slider on the node.
- **Fix:** extend `reservedNames` with the MSL `metal_stdlib` math/relational/derivative/geometric set and
  the `M_*_F` constants, and treat the app's own stdlib names as reserved (derive from
  `MSLStdlib.functions.keys` / the `mn_` prefix rather than listing them). Consider a rule instead of a
  list for calls: an identifier immediately followed by `(` that is not a declared local is a *call*, not a
  socket — sockets in a formula are never called. That one rule also covers user-typed helpers.
  Bodies that compile today are unaffected (none of these names can currently appear without erroring).

### 3. Tokeniser mis-scans numeric literals and accepts non-ASCII identifiers the placeholder grammar cannot substitute
- **Severity:** medium · **Category:** bug · **Confidence:** confirmed
- **Where:** `Codegen/MSLScanner.swift:449-470` (`tokenise`), `NodeRegistry.swift:29` (`placeholderPattern`)
- Two related defects in one place:
  1. The number scanner only accepts digits, `.`, `e/E`, `f/F` and a sign after an exponent. A hex literal
     or any other MSL suffix splits into a number plus a *free identifier*: `0xFF` → `["xFF"]`, `1u` →
     `["u"]`, `0.5h` → `["h"]` (probe). Each becomes an Expression socket and the literal is rewritten
     into nonsense (`0{in.xFF}`).
  2. Identifier start/continue use `Character.isLetter` / `isNumber` (Unicode), but
     `placeholderPattern` is ASCII-only `[A-Za-z_][A-Za-z0-9_]*`. `π * r` scans as sockets `π`, `r`;
     `ExpressionNode.template` rewrites to `{in.π} * {in.r}`; `Emitter.substitute` cannot match `{in.π}`
     and emits it verbatim. Probe output: `v0 = {in.π} * u.p1;`. Same for `x²`, `é`, etc. The node
     *shows* a socket named π and requests a uniform for it, so the UI and the program disagree.
- **Fix:** in `tokenise`, scan a number as `0[xX][0-9a-fA-F]+` or the decimal form, then consume any
  trailing suffix letters (`u`, `U`, `h`, `H`, `f`, `F`, `l`, `L`) into the same token; restrict identifiers
  to ASCII `[A-Za-z_][A-Za-z0-9_]*` (MSL's own rule) so the scanner, the placeholder regex and Metal agree
  on what an identifier is. Alternatively make `placeholderPattern` accept whatever `tokenise` accepts —
  but Metal does accept Unicode letters (verified below), so the ASCII restriction is the safer, simpler
  invariant.

### 4. Duplicate socket names on a group definition trap inside generation instead of producing a diagnostic
- **Severity:** medium · **Category:** bug · **Confidence:** confirmed
- **Where:** `Codegen/TypeResolver.swift:48-49`; no rule in `Codegen/Validation.swift`
- `TypeResolver.resolve` builds `inputTypes`/`outputTypes` with `Dictionary(uniqueKeysWithValues:)` from
  the shape's socket list. Builtins are guaranteed unique by `NodeRegistry.validate`, but a
  `GroupDefinition`'s `inputs`/`outputs` come straight from the file (or a pasted clipboard definition —
  `ClipboardMerge.plan` inserts them verbatim). Two inputs named `a` on a definition whose Group Input is
  wired to its Group Output crash `ShaderGenerator.generate` (`GroupCodegen.function` → `TypeResolver`):
  `Fatal error: Duplicate values for key: 'a'` (probe `dupsockets`). Every preview after opening such a
  file crashes; `GraphValidator.validate` reports nothing first.
- **Fix:** add a structural rule in `GraphValidator.validate(document:)`: for each definition, refuse
  duplicate names within `inputs` and within `outputs` ("Definition “X” declares two inputs named “a”").
  And harden `TypeResolver` with `Dictionary(_, uniquingKeysWith: { a, _ in a })` so an internal caller
  can never trap on it.

### 5. `Timeline` arithmetic traps on a large/non-finite duration and yields NaN time for `frameRate == 0`; only the inspector path is guarded
- **Severity:** medium · **Category:** bug · **Confidence:** confirmed (trap) / confirmed by reading (path)
- **Where:** `Timeline.swift:17` (`frameCount`), `Timeline.swift:45` (`time`), `Timeline.swift:66` (`seek`)
- `frameCount` is `Int((duration * Double(frameRate)).rounded())`. `Int(Double)` traps outside the Int
  range. Probe: `Timeline(duration: 1e300, frameRate: 60).frameCount` →
  `Fatal error: Double value cannot be converted to Int because the result would be greater than Int.max`.
  The UI guards only `EditorModel.setTimeline` (`EditorModel+Recording.swift:61`, `0 < d ≤ 3600`) — the
  comment there even names this trap — but `DocumentSettings.init(from:)` decodes `timeline` unvalidated
  and `EditorModel.load`/`init` call `syncClock()` → `TimelineClock.retarget` → `frameCount` on the decoded
  value, so a file with `"duration": 1e300` (or `1e20`) crashes on open. `frameRate: 0` (not one of
  `frameRates`, but decodable) gives `time == nan` (probe) and every frame renders with `u.time = NaN`.
  `seek(elapsed:)` has the same `Int(Double)` conversion.
- **Fix:** make `Timeline` self-defending rather than relying on every writer: clamp in the decoder
  (`duration = min(max(d.isFinite ? d : 4, 1/60), 3600)`, `frameRate = frameRates.contains(r) ? r : 60`)
  and/or compute `frameCount` through a bounded `Double` before converting:
  ```swift
  public var frameCount: Int {
      let f = (duration * Double(frameRate)).rounded()
      return f.isFinite ? Int(min(max(f, 1), 1e9)) : 1
  }
  ```
  Encoding is unchanged; the corpus documents carry ordinary values.

### 6. NaN/infinite parameter values are representable, make the document unsaveable, and bake as invalid MSL
- **Severity:** medium · **Category:** bug · **Confidence:** confirmed (Core behaviour) / plausible (UI entry)
- **Where:** `ParamValues.swift:48-51` (`f`), `ParamValue.swift:33-35` (`mslLiteral`), encoding of `ParamValue`
- Nothing in Core rejects a non-finite `Float` in a `ParamValue`. Consequences, all confirmed in the probe:
  `JSONEncoder().encode(doc)` throws `Unable to encode Float.nan directly in JSON` (so File ▸ Save fails
  with an opaque error and the user cannot save their work); `ParamValues.mslLiteral(.float(.nan), as: .float)`
  returns `nan` and `.infinity` returns `inf` — `xcrun metal` rejects `nan` as an undeclared identifier, so
  a RealityKit export with a NaN slot does not compile. Entry point: the vector component fields in
  `ParamControl.swift:223-229` are `TextField(value:format: .number…)`, and
  `FloatingPointFormatStyle<Float>.number.parseStrategy.parse("nan")` returns `nan` (probe) — typing
  `nan`/`inf` in a Vector 3 component is enough. No `isFinite` guard exists on the param path anywhere in
  Core or UI (grep).
- **Fix (Core):** sanitise at the boundary the format cannot express — in `ParamValue`'s encoder (custom
  `encode(to:)` replacing non-finite components with 0) or in the one setter the editor funnels through;
  and make `ParamValues.f` spell non-finite as `0.0` (NaN) / `INFINITY` with the sign, so a literal is
  always valid MSL. Both leave finite values byte-identical, so goldens hold.

### 7. An Expression formula ending in a `//` comment swallows the template's terminating `;`
- **Severity:** low · **Category:** bug · **Confidence:** confirmed by reading
- **Where:** `Library/Builtin/ExpressionNode.swift:65-67`, `Codegen/MSLScanner.swift:107-130`
- `rewritingIdentifiers` deliberately passes comments through verbatim; `template(for:)` then wraps the
  result as `"{out.out} = \(body);"`. For `a * 2.0 // half` the emitted line is
  `v0 = u.p0 * 2.0 // half;` — the `;` is inside the comment and Metal reports "expected ';'" on the
  user's line, with the `userLine` map pointing at a formula that looks fine.
- **Fix:** strip comments from the formula in `template(for:)` (the scanner already has `stripComments`;
  make it internal and apply it before hardening), or emit the `;` on its own line.

### 8. Nested loop guards reset per outer iteration, so a nested runaway still hangs the GPU
- **Severity:** low · **Category:** improvement · **Confidence:** confirmed
- **Where:** `Codegen/LoopHardening.swift:66-79`
- Each loop's `int mn_loopGuardN = 0;` is spliced immediately before *its own* keyword, which for an inner
  loop is inside the outer body. Probe output for two nested `for`s: the inner counter is re-declared to 0
  on every outer iteration, so the cap is 4096 × 4096 = 16.7 M iterations per pixel for depth 2, and
  4096³ for depth 3. `while (true) { while (true) {} }` therefore still trips Metal's watchdog — the
  exact outcome §24.4 says the seatbelt exists to prevent. Tests (`nestedLoopsGetOneCounterEach`) pin the
  current shape, so this is a documented-but-weak guarantee rather than a regression.
- **Fix:** declare every guard once at the top of the hardened text (the body is always spliced inside a
  function scope, and `LoopHardening.hardened` already knows all sites up front), or share one counter
  across all loops of a body. Either makes the total bound 4096 per body per invocation.

### 9. `.msl` bodies and Expression formulas are re-tokenised several times per validate/generate; the `scopeBreakers` cache does not cover the hot paths it claims to
- **Severity:** low-medium · **Category:** perf · **Confidence:** confirmed by reading
- **Where:** `Codegen/EmitEnvironment.swift:404-413` (`canEmit(mslText:)`),
  `Codegen/CustomCodeValidation.swift:47-49` (`accessorCallSites` again for the line),
  `Codegen/MaterialValidation.swift:191` (`identifierLines`), `Codegen/LoopHardening.swift:162-163`,
  `NodeShape.swift:58` → `ExpressionNode.swift:71-80` (`sockets` + `generics` each tokenise)
- The `scopeBreakerCache` comment says "with this only the edited body is scanned again", but per
  validation each reachable `.msl` definition is still fully tokenised by `canEmit(mslText:)` (once, plus
  once more for the diagnostic line when it fails), by `identifierLines` under RealityKit, and per generate
  again by `LoopHardening.loopBraceSites`. At the stated ~600 ns/char that is ~2-3 ms per 4 KB body per
  keystroke-debounce, multiplied by the number of definitions. An Expression node's shape tokenises its
  formula twice per `doc.shape(of:)` call, and one generate calls `shape` for it ≥5 times (validation,
  resolver, emitter pass 1, emitter pass 2 ×2) plus `template(for:)` twice more.
- **Fix:** memoise `tokenise(_:)` itself (content-keyed, same bounded `ScanCache`) instead of one derived
  result; every entry point (`identifiers`, `identifierLines`, `accessorCallSites`, `scopeBreakers`,
  `loopSites`, `LoopHardening`) then shares the hit. Have `ExpressionNode.shape` compute the identifier
  list once and derive both `inputs` and `generics` from it.

### 10. Topological sorts and the cycle check scan every wire once per node — O(N·E) per traversal, several traversals per generate
- **Severity:** low · **Category:** perf · **Confidence:** confirmed by reading
- **Where:** `Codegen/TopoSort.swift:10-14`, `Codegen/Validation.swift:169-171`, `Graph.swift:88-101`
- `TopoSort.sources(of:)` filters the whole `inputs` dictionary for every visited node; the validator's
  `sources(of:)` does the same, and `Graph.edges(of:)`/`upstreamNodes` too. A single generate under
  RealityKit performs: validation cycle walk (root + each definition), `stageOrder` ×2, rule-2
  `stageViolations` ×2 (which re-sorts each reachable definition), `definitionNodeDiagnostics` (another
  sort per definition), `GroupCodegen` (one per definition), plus the root order. For a few hundred nodes
  and wires this is tens of thousands of dictionary iterations per keystroke; fine today, quadratic as
  documents grow.
- **Fix:** build a reverse adjacency (`[NodeID: [SocketRef]]`) once per graph at the top of `order`/
  `validate` and index into it. `Graph` could cache it lazily behind `inputs`' `didSet`.

### 11. `ShaderDocument.node(_:)` sorts every definition on each call and is used per uniform field
- **Severity:** low · **Category:** perf · **Confidence:** confirmed by reading
- **Where:** `ShaderDocument.swift:298-304`; callers `ParamValues.swift:11`, `Export/ShaderExport.swift:60,128`,
  `Export/MaterialExport.swift:128`, `Codegen/MaterialValidation.swift:411`
- `node(_:)` sorts `definitions.values` (allocating) before a linear probe, and `bakedUniforms` / the
  export header call it once per layout field. Sorting is unnecessary: node ids are unique document-wide
  (ruling R12), so any hit is *the* hit and iteration order cannot change the answer.
- **Fix:** drop the sort (`for d in definitions.values`), or keep a lazily built `[NodeID: GraphPath]` index.

### 12. A blank socket name silently becomes `metalNodesShader`
- **Severity:** low · **Category:** improvement / API hazard · **Confidence:** confirmed by reading
- **Where:** `Groups/GroupOperations.swift:34, 274` via `Codegen/StitchableCodegen.swift:17-24`
- `uniqueSocketName` and `renameSocket` sanitise through `StitchableCodegen.sanitizedName`, whose
  empty/blank fallback is the *export function's* default name. `renameSocket(…, to: "   ")` therefore
  succeeds and names the socket `metalNodesShader`; `addSocket` with an empty `decl.name` does the same.
  The UI may pre-validate, but the Core API returns success for an input it should refuse.
- **Fix:** give `uniqueSocketName` its own fallback (`"socket"`) or make `renameSocket`/`addSocket` return
  `nil` when the sanitised name is empty, mirroring `rename(_:to:)`'s blank check at line 231.

### 13. `addSocket` refuses texture *outputs* but accepts texture *inputs*, which the emitter cannot call
- **Severity:** low · **Category:** improvement / API hazard · **Confidence:** confirmed by reading (UI blocks it)
- **Where:** `Groups/GroupOperations.swift:247`, `Codegen/Emitter.swift:287`, `Codegen/GroupCodegen.swift:272`
- A `.texture` input declares `texture2d<float> in_x` on the function; an unwired instance input gets no
  uniform (`isUniformable == false`), so the call site falls back to `GroupCodegen.zeroLiteral(.texture)`
  = `"0.0"` and emits `mn_g_…(uv, time, size, mouse, 0.0)` — a type error on generated scaffolding.
  `EditorModel+Groups.swift:206-214` refuses `.texture` for both kinds precisely because Core does not, so
  this is not user-reachable today, but the invariant lives in the wrong layer.
- **Fix:** refuse `.texture` for both kinds in `GroupOperations.addSocket` (one line), and have
  `zeroLiteral(.texture)` be unreachable rather than `"0.0"`.

### 14. Minor correctness/UX nits in Groups and Clipboard
- **Severity:** low · **Category:** improvement · **Confidence:** confirmed by reading
- `Groups/GroupOperations.swift:223` — `makeUnique` names the copy `"\(name) 2"` then uniques *that*,
  so with "Foo 2" already present you get "Foo 2 2" rather than "Foo 3". Pass `def.name` to
  `uniqueDefinitionName` and let it pick the suffix.
- `Clipboard/GraphClipboard.swift:144-145` — "identical" is judged by `contentHash` of the definition
  *alone*; a definition whose own graph is unchanged but which instantiates a nested definition that
  *did* diverge is reused as-is, so the pasted instance renders with the destination's nested body, not
  the source's. Low impact; worth a comment or hashing the transitive closure.
- `Persistence/ShaderPackage.swift:41-43` — `fileName(for:info:)` interpolates `info.fileExtension`
  unsanitised; a hand-edited `"fileExtension": "png/../x"` reaches `FileWrapper.addRegularFile(preferredFilename:)`,
  which raises an ObjC exception on `/`. Strip path separators (and empty extensions) when decoding
  `AssetInfo`.
- `Codegen/MSLScanner.swift:176-186` — `declaredLocals` ignores declaration order (a use *before*
  `float d = …` is treated as bound) and only recognises scalar/vector type names, so `sampler s` or a
  user struct type leaves `s` free. Harmless for formulas today; document it or scan in order.

---

## What I checked and found clean

- **Emitter invariants.** Every force-unwrap in `Emitter.emit` (`inputTypes[…]!`, `outputTypes[…]!`,
  `layout.field(for:)!`, `textureSlots[…]!`, `convert(from:to:)!`) was traced to its guarantee: shapes
  are read through the same `doc.shape(of:)` the resolver used; every uniform/texture the second pass
  reads was requested in the first (including group `uniformParams`/`textureParams` and shared
  RealityKit bindings); `TypeResolver` reports non-convertible wires and `generate` throws before emit.
- **Conversion matrix** (`Conversion.swift`): every from/to pair produces valid MSL; identity for
  `color↔float4`; scalar broadcast and vector truncation spellings correct; texture refused up front.
- **UniformLayout**: alignment-descending stable sort, `float3` as 16 bytes, `bool` stored as `int`,
  `p\(n)` naming unique; `ParamValues.int32(from:)` cannot trap (Double clamp).
- **LoopHardening splice logic**: line/column mapping, whitespace-prefix carry-over, wrapping for
  unbraced `if/else/case` slots, `do … while (…);` wrap-close offset, `userLines` parallelism, CRLF
  normalisation agreeing with `MSLScanner.Token.start`.
- **`do`/`while` pairing** in `loopOpeners` (nested `do` frames by brace depth) and the documented
  unbraced-`do` gap, which `scopeBreakers` closes by refusing unbraced bodies.
- **Expression template injection**: a formula typing `{sys.mouse}`/`{out.out}` cannot reach
  `Emitter.substitute` as a placeholder — `rewritingIdentifiers` rewrites `sys`/`out` first.
- **Unicode in generated identifiers**: `xcrun metal` compiles `mn_g_Größe_…` and `mn_g_日本語_…`
  (tested), so `sanitizedName` keeping non-ASCII letters is not a compile problem; emoji collapse to `_`.
- **`1e+10` / `-0.0` literals** from `ParamValues.f` compile (tested).
- **GroupCodegen `.msl` scaffolding**: zero-initialised outputs, `uniqueResultVar` total, reserved
  `uv/time/size/mouse` derived from one list and enforced by `mslNameCollides`; `.msl` layer variants
  never built (no `textureParams`), matching the Layer Effect design.
- **Group operations**: `group()` refuses terminals/pseudo-nodes/self-instances, uniques boundary
  sockets per source socket, remints nothing it should not; `ungroup` handles pass-through outputs and
  unwired inputs by copying values; `renameSocket`/`removeSocket` rewrite every instance in every graph
  and the `Dictionary(uniqueKeysWithValues:)` rebuilds there keep keys unchanged (no trap risk).
- **ClipboardMerge**: remap of nested `.group` kinds runs after the whole plan is built, so ordering by
  id cannot miss a nested remap; `materialize` remints ids so repeated pastes never collide;
  `contentHash` is deterministic (`sortedKeys`, sorted node/edge arrays).
- **RealityKit two-pass codegen**: probe → shared bindings → emit ×4 with identical orders; viewer
  widening validated against surface-stage legality; `hasGeometryWork` is the single predicate for both
  the export text and `stageFunctionNames`; `stageReferences` uses `\b` so `tex1` ≠ `tex10`.
- **MaterialValidation rules 2–6** agree with the environments (`readableSys`, fill-only keys derived,
  live-parameter count/duplicate/type checks, texture-slot dedup by asset matching `requestTexture`).
- **Document format tolerance**: `DocumentSettings` degrades unknown `target`/`lightingModel`, defaults
  every missing key, and dedups `assets`; `GroupDefinition` accepts both `body` and legacy `graph`;
  `DefinitionBody` refuses an unknown `kind` loudly (correct choice); `ShaderPackage.VersionProbe` gates
  newer formats; `EditorViewState` decodes every key optionally.
- **TimelineClock transitions** (`step`, `seek`, `scrub`, `reset`, `retarget`) are correct for the
  documented in-range inputs; only the range itself is unguarded (finding 5).
- **TopoSort/Validation cycle handling**: DFS with on-stack set terminates on cycles; validation reports
  each back-edge; `orderAll` covers unreachable nodes for `group()` typing.
- **StitchableCodegen**: argument order, `half4` colour narrowing in the preview call, `[[stitchable]]`
  signature per kind, layer-variant selection at call sites (`usesLayer && !textureParams.isEmpty`).
- **Sendable/concurrency**: `MSLScanner.scopeBreakerCache` behind `Mutex`; `EmitEnvironment` closures
  `@Sendable` and `bakedUniforms` snapshots strings before capturing; `NodeRegistry.placeholderPattern`
  is `nonisolated(unsafe)` on an immutable `Regex` — acceptable.
