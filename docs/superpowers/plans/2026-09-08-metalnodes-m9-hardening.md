# MetalNodes M9 — Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close handoff §15.5 — the behaviour changes M8 shipped, the defects the 2026-09-08 in-app walk found, the duplication and cost the reviews measured, and the build floor — without changing what any document means.

**Architecture:** Thirteen independent fixes across `MetalNodesCore` (scanner, hardener, validation, material codegen), `MetalNodesUI` (node label column, menu commands), the test targets (one Metal-compiler helper), and the project (iOS floor, test scheme). The document format stays at version 2 and the backward-compatibility corpus's goldens do not move, except the aspect-UV diagnostic text, which is re-pinned deliberately. Each fix ships with a test that fails against the pre-fix code.

**Tech Stack:** Swift 6.4 (`.swiftLanguageMode(.v6)`, strict concurrency, `Synchronization.Mutex`), SwiftUI/AppKit, Swift Testing, `xcrun -sdk macosx metal` for real compiles, Xcode 26.6 for `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` §25 (M9 addendum). §25 wins wherever it and §23/§24 differ. Handoff: `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` §15.5 (the item numbers below refer to it).

## Global Constraints

- **The document format stays at version 2.** `ShaderDocument.currentFormatVersion` is not touched; no `Codable` shape changes.
- **The corpus goldens do not move**, except the aspect-UV message (Task 2). `swift test --filter FormatCorpusTests` must pass at the end of every task; a task that needs a golden to change is wrong.
- **Never commit `MetalNodes.xcodeproj/project.pbxproj`**, except Task 12, whose diff must be exactly the four `IPHONEOS_DEPLOYMENT_TARGET` lines. After every `xcodebuild`, run `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.
- **Xcode 26.6 is the Xcode Cloud toolchain.** Every `xcodebuild` in this plan is run as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`. `swift build` / `swift test` run from `MetalNodesKit/`.
- **Warning-free.** `swift build` prints zero `warning:` lines; `xcodebuild` for macOS and `generic/platform=iOS` prints zero.
- **No placeholder text reaches generated source** — every codegen test keeps its `!s.contains("/* ?")` guard.
- **The user's own text is never rewritten** (§24.4): hardening and scanning normalise their own copies only.
- **Every fix has a mutation check:** after the tests pass, revert the production change once, confirm the new test fails, restore it. Record the result in the report.
- **Commit trailers:**
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```

## File Structure

| File | Responsibility in M9 |
|---|---|
| `MetalNodesKit/Tests/MetalNodesCoreTests/Support/MetalCompiler.swift` | **New.** The one `xcrun metal` seam for tests (Task 1). |
| `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift` | Aspect-UV hint (Task 2). |
| `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift` | Slider ranges (Task 3). |
| `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift` | CRLF at the source (Task 4), one comment skipper (Task 5), shared loop openers (Task 6), scan cache (Task 7). |
| `MetalNodesKit/Sources/MetalNodesCore/Codegen/CustomCodeValidation.swift` | Loses `normalisedForScanning` (Task 4); scans the trimmed formula (Task 11). |
| `MetalNodesKit/Sources/MetalNodesCore/Codegen/LoopHardening.swift` | Consumes the scanner's openers (Task 6). |
| `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift`, `ShaderGenerator.swift` | Geometry-stage predicate reads the terminal's edited values (Task 8). |
| `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeGeometry.swift`, `ParamControl.swift`, `NodeView.swift`, `Editor/InspectorView.swift`, `Editor/InspectorView+Groups.swift` | Per-shape label column (Task 9). |
| `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift` | ⌘Z forwards to a focused text view on macOS (Task 10). |
| `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift`, `EmitEnvironment.swift`, `ShaderGenerator.swift` | Sweep (Task 11). |
| `MetalNodesKit/Package.swift`, `MetalNodes.xcodeproj/project.pbxproj`, `MetalNodes.xcodeproj/xcshareddata/xcschemes/MetalNodes.xcscheme` | iOS floor, test env (Task 12). |
| `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` | §16, the M9 execution record (Task 13). |

## Parallel waves (for the controller)

Tasks whose file sets are disjoint may run in parallel worktrees. Tasks 4 → 5 → 6 → 7 all edit `MSLScanner.swift` and are **serial**, in that order.

- **Wave A (parallel):** Task 1 (test support), Task 2 (MaterialValidation), Task 3 (Material3DNodes), Task 9 (UI geometry), Task 10 (EditorCommands), Task 12 (build).
- **Wave B (serial):** Task 4, Task 5, Task 6, Task 7 — after Task 1 lands, because Task 6's compile gate uses `MetalCompiler`.
- **Wave C (parallel):** Task 8 (MaterialCodegen/ShaderGenerator — after Task 1), Task 11 (sweep — after Tasks 4 and 8, since it touches `CustomCodeValidation` and `ShaderGenerator`).
- **Task 13** last, by the controller.

---

### Task 1: One Metal compiler probe for the tests

**Files:**
- Create: `MetalNodesKit/Tests/MetalNodesCoreTests/Support/MetalCompiler.swift`
- Modify: `MetalNodesKit/Tests/MetalNodesCoreTests/LoopHardeningTests.swift:12-46`, `MaterialExportTests.swift:109-118, 213-231`, `CustomMSLDefinitionTests.swift:443-490`, `ExpressionNodeTests.swift:197-235`, `FragmentExportTests.swift:94-120`, `LayerVariantTests.swift:199-225`, `SampleDocumentTests.swift:56-85`

**Interfaces:**
- Produces: `enum MetalCompiler { static let isAvailable: Bool; static func compile(_ source: String, fileName: String = "test.metal", extraArgs: [String] = []) throws -> MetalCompiler.Result; @discardableResult static func expectCompiles(_ source: String, extraArgs: [String] = [], _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool }` with `struct Result { let status: Int32; let log: String }`. Tasks 6 and 8 use `expectCompiles`.

- [ ] **Step 1: Write the helper**

```swift
// MetalNodesKit/Tests/MetalNodesCoreTests/Support/MetalCompiler.swift
import Foundation
import Testing

/// The one `xcrun metal` seam for every test that proves generated text is real MSL (spec §25.4).
/// Ten test files carried their own copy of this probe and compile step before M9.
enum MetalCompiler {
    struct Result {
        let status: Int32
        let log: String
    }

    /// True when `xcrun -sdk macosx metal --version` succeeds. Probed once per process — the
    /// toolchain does not appear mid-run.
    static let isAvailable: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-sdk", "macosx", "metal", "--version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    /// Writes `source` to a fresh temporary directory as `fileName` and runs
    /// `xcrun -sdk macosx metal <extraArgs> -c <file> -o out.air`. `extraArgs` is spliced ahead of
    /// `-c` so a caller can pin `-mmacosx-version-min=…`.
    static func compile(_ source: String, fileName: String = "test.metal", extraArgs: [String] = []) throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-metal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try source.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-sdk", "macosx", "metal"] + extraArgs
            + ["-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Result(status: p.terminationStatus, log: log)
    }

    /// Records an issue carrying the compiler's stderr when `source` does not compile. Skips
    /// silently (returns true) when the toolchain is not installed, matching every pre-M9 site.
    @discardableResult
    static func expectCompiles(_ source: String, extraArgs: [String] = [], _ comment: String = "",
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool {
        guard isAvailable else { return true }
        let r = try compile(source, extraArgs: extraArgs)
        #expect(r.status == 0, Comment(rawValue: "\(comment)\n\(r.log)"), sourceLocation: sourceLocation)
        return r.status == 0
    }
}
```

- [ ] **Step 2: Run the existing suite to confirm it still builds with the new file**

Run: `cd MetalNodesKit && swift test --filter LoopHardeningTests`
Expected: PASS (nothing uses the helper yet; the file must compile).

- [ ] **Step 3: Replace the seven inline copies**

The pattern at every site is the same two pieces. Before (`MaterialExportTests.swift:109-118`):

```swift
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }
```

After:

```swift
        guard MetalCompiler.isAvailable else { return }
```

Before (`MaterialExportTests.swift:217-231`, the compile step):

```swift
    private func expectMetalCompiles(_ doc: ShaderDocument, extraArgs: [String] = []) throws {
        let file = try #require(ShaderExport.files(for: doc).first { $0.name.hasSuffix(".metal") })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-materialexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.name)
        try file.contents.write(to: url, atomically: true, encoding: .utf8)
        let metal = Process()
        metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        metal.arguments = ["-sdk", "macosx", "metal"] + extraArgs
            + ["-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
        try metal.run(); metal.waitUntilExit()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(metal.terminationStatus == 0,
               "\(doc.settings.exportName)\(extraArgs.isEmpty ? "" : " \(extraArgs.joined(separator: " "))"): \(log)")
    }
```

After:

```swift
    private func expectMetalCompiles(_ doc: ShaderDocument, extraArgs: [String] = []) throws {
        let file = try #require(ShaderExport.files(for: doc).first { $0.name.hasSuffix(".metal") })
        try MetalCompiler.expectCompiles(file.contents, extraArgs: extraArgs,
            "\(doc.settings.exportName)\(extraArgs.isEmpty ? "" : " \(extraArgs.joined(separator: " "))")")
    }
```

Apply the same two replacements in each of these, keeping every test's own source-assembly (the kernel wrapper in `LoopHardeningTests.compiles`, the export lookup elsewhere) and every existing assertion:

| File | Probe lines | Compile lines |
|---|---|---|
| `LoopHardeningTests.swift` | `compiles(_:)` lines 13-19 → `guard MetalCompiler.isAvailable else { return true }` | lines 31-45 → `let r = try MetalCompiler.compile(source); if r.status != 0 { Issue.record("metal -c failed for hardened body:\n\(hardened)\n\n\(r.log)"); return false }; return true` |
| `MaterialExportTests.swift` | 111-117 | 217-231 (above) |
| `CustomMSLDefinitionTests.swift` | 444-450 | 486-495 |
| `ExpressionNodeTests.swift` | 198-204 | 228-237 |
| `FragmentExportTests.swift` | 95-101 | 111-120 |
| `LayerVariantTests.swift` | 200-206 | 215-224 |
| `SampleDocumentTests.swift` | 57-63 | `expectMetalCompiles` 71-85 |

`ShaderExportTests.swift` probes `swiftc`, not `metal`; leave it alone. `LiveParametersTests.swift` and `MaterialCodegenTests.swift` only mention `xcrun` in comments.

- [ ] **Step 4: Confirm no inline probe remains and the suite is green**

Run: `cd MetalNodesKit && grep -rn '"metal", "--version"' Tests | grep -v Support/MetalCompiler.swift; swift test 2>&1 | grep -E "warning:|error:|Test run with"`
Expected: the grep prints nothing; three `Test run with … passed` lines; no warnings.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Tests
git commit -m "test: one MetalCompiler helper replaces seven inline xcrun metal probes"
```

---

### Task 2: The aspect-UV refusal names its fix (item 4)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift:121-138`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift`, `FormatCorpusTests.swift:102`

**Interfaces:**
- Consumes: `MaterialValidation.targetDiagnostics` (the function at lines 119-138, whose `problem`/`fix` strings this task extends).
- Produces: the exact message `UV reads resolution, which the RealityKit Material target does not provide — this node needs the Fragment (preview) or SwiftUI target, or switch this node's Mode to Normalized` for a UV node in aspect mode; every other node's message is unchanged.

- [ ] **Step 1: Write the failing tests**

In `MaterialValidationTests.swift`, after `mouseAndResolutionAreRefusedUnderRealityKit`:

```swift
    /// Spec §25.2 (handoff §15.5 item 4): the refusal stands, and its message now says what to do.
    @Test func anAspectModeUVUnderRealityKitNamesTheModeSwitch() {
        let doc = MaterialFixture.document { g in
            let uv = MaterialFixture.wire("input.uv", into: "baseColor", &g)
            g.nodes[uv]!.params["mode"] = .enumCase("aspect")
        }
        let messages = errors(doc).map(\.message)
        #expect(messages.count == 1)
        #expect(messages.first?.hasSuffix(", or switch this node's Mode to Normalized") == true, "\(messages)")
    }

    /// Only the UV node carries the hint — a Mouse node has no mode to switch.
    @Test func theModeHintIsNotAddedToOtherRefusals() {
        let doc = MaterialFixture.document { g in MaterialFixture.wire("input.mouse", into: "baseColor", &g) }
        #expect(errors(doc).allSatisfy { !$0.message.contains("Mode to Normalized") })
    }
```

`MaterialFixture.wire` returns the new node's id (`@discardableResult`), and the UV node's mode param is named `mode` with cases `normalized`/`aspect` (`MaterialFixture` and `errors(_:)` are in this file already). In `FormatCorpusTests.swift`, change line 102's expected string to:

```swift
        #expect(diags.first?.message == "UV reads resolution, which the RealityKit Material target does not provide — this node needs the Fragment (preview) or SwiftUI target, or switch this node's Mode to Normalized")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd MetalNodesKit && swift test --filter "MaterialValidationTests|FormatCorpusTests"`
Expected: `anAspectModeUVUnderRealityKitNamesTheModeSwitch` and `aspectUVUnderRealityKitIsRefused` FAIL on the message; `theModeHintIsNotAddedToOtherRefusals` passes.

- [ ] **Step 3: Add the hint**

In `MaterialValidation.targetDiagnostics`, replace the last three lines of the closure (`guard let fix … return Diagnostic(.error, problem + " — this node needs the \(fix) target", node: inst.id)`) with:

```swift
            // A UV node in aspect mode is the one refusal a user can fix in place — §24.10 kept the
            // refusal, §25.2 makes the message say so. Keyed on the def and the chosen case rather
            // than on the missing name, so a future node that also reads `resolution` does not
            // inherit advice about a mode it does not have.
            let modeHint = (id == "input.uv" && chosen == "aspect") ? ", or switch this node's Mode to Normalized" : ""
            guard let fix = alternativeTargets(for: def.body, chosen: chosen, excluding: target) else {
                return Diagnostic(.error, problem + modeHint, node: inst.id)
            }
            return Diagnostic(.error, problem + " — this node needs the \(fix) target" + modeHint, node: inst.id)
```

`id` is the builtin id bound by `guard case .builtin(let id) = inst.kind` at the top of the closure, and `chosen` is `def.variantCase(for: inst)`; both already exist there. Confirm the UV node's aspect case is spelled `aspect` with `grep -n '"aspect"' Sources/MetalNodesCore/Library/Builtin/*.swift` before writing the string.

- [ ] **Step 4: Run the tests, then the mutation check**

Run: `cd MetalNodesKit && swift test --filter "MaterialValidationTests|FormatCorpusTests"`
Expected: PASS. Then temporarily set `modeHint` to `""`, re-run, confirm the two message tests FAIL, restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift MetalNodesKit/Tests/MetalNodesCoreTests/FormatCorpusTests.swift
git commit -m "fix(validation): the aspect-UV refusal under RealityKit says to switch the mode to Normalized"
```

---

### Task 3: Every Material Output float slider spans 0…1 (item 7)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift:24-36`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/Material3DLibraryTests.swift`

- [ ] **Step 1: Write the failing correspondence test**

Append to the suite in `Material3DLibraryTests.swift`:

```swift
    /// Spec §25.2 (handoff §15.5 item 7): a float socket on the terminal is a 0…1 quantity by
    /// definition, and the slider's own default is −10…10. Correspondence, so the next socket
    /// cannot forget — clearcoat did until the 2026-09-08 walk baked `set_clearcoat(half(-10.0))`.
    @Test func everyFloatInputOfMaterialOutputDeclaresAUnitRange() throws {
        let def = try #require(NodeRegistry.builtin["output.material"])
        for decl in def.inputs where decl.type == .concrete(.float) {
            #expect(decl.range == 0...1, "\(decl.name) declares \(String(describing: decl.range))")
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd MetalNodesKit && swift test --filter everyFloatInputOfMaterialOutputDeclaresAUnitRange`
Expected: FAIL, naming `roughness`, `metallic`, `opacity`, `occlusion`, `specular`.

- [ ] **Step 3: Declare the ranges**

In `Material3DNodes.swift`, add `, range: 0...1` to the five declarations so each reads like:

```swift
                    SocketDecl(name: "roughness", label: "Roughness", type: .concrete(.float),
                               default: .value(.float(0.5)), range: 0...1),
```

for `roughness`, `metallic`, `opacity`, `occlusion`, `specular`. Move the existing comment above `clearcoat` (`// \`range:\` because both are 0…1 by definition …`) up to sit above `roughness`, and change its first words to `// \`range:\` on every float here because all are 0…1 by definition`.

- [ ] **Step 4: Run the test and the corpus**

Run: `cd MetalNodesKit && swift test --filter "Material3DLibraryTests|FormatCorpusTests|MaterialCodegenTests"`
Expected: PASS — a range is a UI hint; no emitted text changes.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift MetalNodesKit/Tests/MetalNodesCoreTests/Material3DLibraryTests.swift
git commit -m "fix(library): every Material Output float socket declares a 0...1 slider range"
```

---

### Task 4: CRLF is normalised once, in the scanner (item 6)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift:101-114, 178-187, 320-323, 356-359`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/CustomCodeValidation.swift:16, 26, 44, 54-64`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift:189` (the `identifierLines(in: CustomCodeValidation.normalisedForScanning(text))` call)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift`, `CustomCodeValidationTests.swift:128-135` (existing, kept)

**Interfaces:**
- Produces: `MSLScanner.normalisedLineEndings(_ source: String) -> String` (internal, `static`). Every public scanner entry point counts lines on the normalised text. `rewritingIdentifiers` returns text with `\n` endings.
- Removes: `CustomCodeValidation.normalisedForScanning(_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `MSLScannerTests.swift`:

```swift
    /// Spec §25.2 (handoff §15.5 item 6): line counting is the scanner's job, on every path — a
    /// Windows-pasted body must not report line 0 for everything.
    @Test func scopeBreakersCountCRLFLines() {
        let v = MSLScanner.scopeBreakers(in: "out = 1.0;\r\nout = 2.0;\r\nreturn;")
        #expect(v == [MSLScanner.Violation(kind: .bareReturn, line: 2)])
    }

    @Test func aPreprocessorLineAfterCRLFIsReportedOnItsOwnLine() {
        let v = MSLScanner.scopeBreakers(in: "out = 1.0;\r\n#include <x>\r\n")
        #expect(v == [MSLScanner.Violation(kind: .preprocessor("include"), line: 1)])
    }

    @Test func identifierLinesCountCRLFLines() {
        #expect(MSLScanner.identifierLines(in: "a\r\n+ b")["b"] == 1)
    }

    @Test func rewritingIdentifiersSplicesCorrectlyAcrossCRLF() {
        let out = MSLScanner.rewritingIdentifiers(in: "a\r\n+ b") { "{\($0)}" }
        #expect(out == "{a}\n+ {b}")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd MetalNodesKit && swift test --filter MSLScannerTests`
Expected: the four new tests FAIL (line 0 reported, or a mis-spliced rewrite).

- [ ] **Step 3: Normalise in the scanner**

In `MSLScanner.swift`, add after the `reservedNames` set:

```swift
    /// `\r\n` and `\r` become `\n` before any scan. Swift folds `\r\n` into one `Character`, so a
    /// Windows-pasted body would otherwise be one giant line to `tokenise` and `stripComments`
    /// alike — every `Token.line` and `Violation.line` 0 (spec §25.2, handoff §15.5 item 6). Every
    /// entry point below scans the normalised copy; `LoopHardening.hardened` normalises its own
    /// copy the same way, because it splices by `Token.start` into *its* text and the two must
    /// agree. Cheap when there is nothing to do, which is the usual case.
    static func normalisedLineEndings(_ source: String) -> String {
        // `utf8`, not `contains("\r")`: a `\r\n` pair is *one* `Character`, so a `Character`-level
        // search for "\r" would miss exactly the input this function exists for.
        guard source.utf8.contains(0x0D) else { return source }
        return source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
```

Then:
- `rewritingIdentifiers(in:with:)`: change `let chars = Array(source)` / `let tokens = tokenise(source)` to `let source = normalisedLineEndings(source)` on a first line, then `let chars = Array(source)` and `let tokens = tokenise(source)` as before. Add to its doc comment: `The result uses \`\n\` line endings whatever the input used.`
- `scopeBreakers(in:)`: first line becomes `let source = normalisedLineEndings(source)`.
- `stripComments(_:)`: `let chars = Array(normalisedLineEndings(source))`.
- `tokenise(_:)`: `let chars = Array(normalisedLineEndings(source))`.

`identifiers`, `identifierLines`, `accessorCallSites`, `loopSites` all go through `tokenise`, so they are covered.

- [ ] **Step 4: Delete the workaround**

In `CustomCodeValidation.swift`: delete `normalisedForScanning` (lines 54-64 including its comment); at lines 16, 26 and 44 replace `normalisedForScanning(formula)` / `normalisedForScanning(text)` with `formula` / `text`. In `MaterialValidation.swift:189` replace `CustomCodeValidation.normalisedForScanning(text)` with `text`. `grep -rn normalisedForScanning Sources` must print nothing.

- [ ] **Step 5: Run the scanner, validator and hardening suites, then the mutation check**

Run: `cd MetalNodesKit && swift test --filter "MSLScannerTests|CustomCodeValidationTests|LoopHardeningTests|MaterialValidationTests|ExpressionNodeTests"`
Expected: PASS, including the existing `aCRLFDefinitionBodyStillReportsThePhysicalLineNumber` (which now passes through the scanner, not the deleted workaround). Mutation: make `normalisedLineEndings` return `source` unchanged, re-run, confirm the four new tests *and* `aCRLFDefinitionBodyStillReportsThePhysicalLineNumber` FAIL, restore.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift MetalNodesKit/Sources/MetalNodesCore/Codegen/CustomCodeValidation.swift MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift
git commit -m "fix(scanner): normalise CRLF once in MSLScanner; drop the validator's local workaround"
```

---

### Task 5: One comment skipper (item 14)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift` (`stripComments`, `tokenise`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift` (existing suite is the gate; two edge tests added)

**Interfaces:**
- Produces: `private static func commentEnd(at i: Int, in chars: [Character]) -> Int?` in `MSLScanner`.

- [ ] **Step 1: Write the edge tests (they pass today and must keep passing)**

Append to `MSLScannerTests.swift`:

```swift
    /// The two comment passes share one skipper after Task 5; these pin the edges either could
    /// get wrong on its own: an unterminated block comment, and a `//` on the last line.
    @Test func anUnterminatedBlockCommentSwallowsTheRestWithoutCrashing() {
        #expect(MSLScanner.identifiers(in: "a /* never closed b").isEmpty == false)
        #expect(MSLScanner.identifiers(in: "a /* never closed b") == ["a"])
        #expect(MSLScanner.scopeBreakers(in: "a /* { never closed").isEmpty)
    }

    @Test func aLineCommentOnTheLastLineEndsAtTheText() {
        #expect(MSLScanner.identifiers(in: "a // b") == ["a"])
        #expect(MSLScanner.scopeBreakers(in: "out = 1.0; // #include") .isEmpty)
    }
```

Run: `cd MetalNodesKit && swift test --filter MSLScannerTests` — Expected: PASS.

- [ ] **Step 2: Extract the skipper and use it in both passes**

Add to `MSLScanner`, above `stripComments`:

```swift
    /// The end (exclusive) of the comment that starts at `chars[i]`, or `nil` when no comment
    /// starts there. A `//` comment ends at its newline, which is *not* consumed — both callers
    /// need it, one to count and one to keep. A `/* … */` comment ends after its `*/`, or at the
    /// text's end when unterminated. One routine, two readers (spec §25.3, handoff §15.5 item 14):
    /// `tokenise` skips the span, `stripComments` blanks it.
    private static func commentEnd(at i: Int, in chars: [Character]) -> Int? {
        guard chars[i] == "/", i + 1 < chars.count else { return nil }
        if chars[i + 1] == "/" {
            var j = i + 2
            while j < chars.count, chars[j] != "\n" { j += 1 }
            return j
        }
        if chars[i + 1] == "*" {
            var j = i + 2
            while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
            return min(j + 2, chars.count)
        }
        return nil
    }
```

Replace `stripComments`'s two `if c == "/", …` blocks (the `//` and `/*` branches) with:

```swift
            if let end = commentEnd(at: i, in: chars) {
                for k in i..<end { out.append(chars[k] == "\n" ? "\n" : " ") }
                i = end
                continue
            }
```

Replace `tokenise`'s two `if c == "/", …` blocks with:

```swift
            if let end = commentEnd(at: i, in: chars) {
                line += chars[i..<end].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                i = end
                continue
            }
```

- [ ] **Step 3: Run the whole scanner-dependent set**

Run: `cd MetalNodesKit && swift test --filter "MSLScannerTests|CustomCodeValidationTests|LoopHardeningTests|ExpressionNodeTests|CustomMSLDefinitionTests|FormatCorpusTests"`
Expected: PASS, byte-identical behaviour. Mutation: make `commentEnd` return `nil` for `/*`, confirm `anUnterminatedBlockCommentSwallowsTheRestWithoutCrashing` and existing comment tests FAIL, restore.

- [ ] **Step 4: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift
git commit -m "refactor(scanner): stripComments and tokenise share one comment skipper"
```

---

### Task 6: LoopHardening consumes the scanner's loop openers (item 13)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift:210-309` (`LoopOpener`, `loopOpeners`, `isBracedAfterParenthesizedHeader`)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/LoopHardening.swift:158-214, 301-330` (`loopBraceSites`, `bracedHeaderBraceIndex`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LoopHardeningTests.swift`

**Interfaces:**
- Produces (internal, in `MSLScanner`): `struct LoopOpener { let line: Int; let keywordIndex: Int; let braceIndex: Int?; let isDo: Bool; var isBraced: Bool }`, `static func loopOpeners(_ tokens: [Token]) -> [LoopOpener]`, `static func bracedHeaderBraceIndex(_ tokens: [Token], headerStart: Int) -> Int?`.
- `loopSites(in:)`, `scopeBreakers(in:)` keep their signatures and results.

- [ ] **Step 1: Pin today's output before touching anything**

Append to `LoopHardeningTests.swift` (these strings were captured from the pre-M9 hardener on 2026-09-08; the refactor must reproduce them byte for byte):

```swift
    /// Byte-for-byte goldens of the pre-M9 hardener over the shapes that matter (spec §25.3,
    /// handoff §15.5 item 13): the gate for folding `loopBraceSites` into `MSLScanner`.
    @Test func hardeningOutputIsUnchangedByTheScannerFold() {
        let cases: [(body: String, text: String, lines: [Int?])] = [
            ("for (int i = 0; i < 4; i++) { s += 1.0; }",
             "int mn_loopGuard0 = 0;\nfor (int i = 0; i < 4; i++) {\n    if (++mn_loopGuard0 > 4096) { break; }\n s += 1.0; }",
             [nil, 0, nil, 0]),
            ("while (a > 0.0) { a -= 1.0; }",
             "int mn_loopGuard0 = 0;\nwhile (a > 0.0) {\n    if (++mn_loopGuard0 > 4096) { break; }\n a -= 1.0; }",
             [nil, 0, nil, 0]),
            ("do { s += 1.0; } while (s < 4.0);",
             "int mn_loopGuard0 = 0;\ndo {\n    if (++mn_loopGuard0 > 4096) { break; }\n s += 1.0; } while (s < 4.0);",
             [nil, 0, nil, 0]),
            ("if (a > 0.0) for (int i = 0; i < 4; i++) { s += 1.0; }",
             "if (a > 0.0) \n{\nint mn_loopGuard0 = 0;\nfor (int i = 0; i < 4; i++) {\n    if (++mn_loopGuard0 > 4096) { break; }\n s += 1.0; }\n}",
             [0, nil, nil, 0, nil, 0, nil]),
            ("if (a > 0.0) { s = 1.0; } else while (s > 0.0) { s -= 1.0; }",
             "if (a > 0.0) { s = 1.0; } else \n{\nint mn_loopGuard0 = 0;\nwhile (s > 0.0) {\n    if (++mn_loopGuard0 > 4096) { break; }\n s -= 1.0; }\n}",
             [0, nil, nil, 0, nil, 0, nil]),
            ("switch (int(a)) { case 1: for (int i = 0; i < 4; i++) { s += 1.0; } break; default: break; }",
             "switch (int(a)) { case 1: \n{\nint mn_loopGuard0 = 0;\nfor (int i = 0; i < 4; i++) {\n    if (++mn_loopGuard0 > 4096) { break; }\n s += 1.0; }\n}\n break; default: break; }",
             [0, nil, nil, 0, nil, 0, nil, 0]),
            ("if (a > 0.0) for (int i = 0; i < 4; i++) { for (int j = 0; j < 4; j++) { s += 1.0; } }",
             "if (a > 0.0) \n{\nint mn_loopGuard0 = 0;\nfor (int i = 0; i < 4; i++) {\n    if (++mn_loopGuard0 > 4096) { break; }\nint mn_loopGuard1 = 0;\n for (int j = 0; j < 4; j++) {\n    if (++mn_loopGuard1 > 4096) { break; }\n s += 1.0; } }\n}",
             [0, nil, nil, 0, nil, nil, 0, nil, 0, nil]),
            ("for (int i = 0; i < 4; i++)\n{\n    s += 1.0;\n}",
             "int mn_loopGuard0 = 0;\nfor (int i = 0; i < 4; i++)\n{\n    if (++mn_loopGuard0 > 4096) { break; }\n    s += 1.0;\n}",
             [nil, 0, 1, nil, 2, 3]),
            ("do { do { s += 1.0; } while (a > 1.0); } while (a > 2.0);",
             "int mn_loopGuard0 = 0;\ndo {\n    if (++mn_loopGuard0 > 4096) { break; }\nint mn_loopGuard1 = 0;\n do {\n    if (++mn_loopGuard1 > 4096) { break; }\n s += 1.0; } while (a > 1.0); } while (a > 2.0);",
             [nil, 0, nil, nil, 0, nil, 0]),
        ]
        for c in cases {
            let h = LoopHardening.hardened(c.body)
            #expect(h.text == c.text, Comment(rawValue: c.body))
            #expect(h.userLines == c.lines, Comment(rawValue: c.body))
        }
    }
```

Run: `cd MetalNodesKit && swift test --filter hardeningOutputIsUnchangedByTheScannerFold` — Expected: PASS against today's code. If any case fails here, stop: the golden was mis-transcribed, and the correct value is whatever the *current* hardener prints — fix the literal, not the code.

- [ ] **Step 2: Widen the scanner's opener**

In `MSLScanner.swift` replace the private `LoopOpener` struct and `loopOpeners` with:

```swift
    /// A `for`, non-closing `while`, or `do` that opens a loop: its line, its keyword's index in
    /// the token array, and the index of the `{` opening its body — `nil` for an unbraced body.
    /// Internal so `LoopHardening` splices by these indices instead of re-deriving them (spec
    /// §25.3, handoff §15.5 item 13).
    struct LoopOpener {
        let line: Int
        let keywordIndex: Int
        let braceIndex: Int?
        let isDo: Bool
        var isBraced: Bool { braceIndex != nil }
    }

    /// Every loop-opening `for`/`while`/`do` in `tokens`, in the order encountered, alongside
    /// where each one's body brace is. A `do`'s own closing `while` is excluded: it is
    /// recognised by brace depth, not by simple order — each `do` that opens a `{ … }` body is
    /// paired with the `while` that follows once that block's closing `}` has brought the brace
    /// depth back down to where the `do` was seen. That is what keeps a *nested*
    /// `do { do { } while (a); } while (b);` from reporting the outer closing `while` as a third,
    /// spurious opener.
    ///
    /// A `do` whose body is a single statement with no braces is a known gap in that pairing:
    /// there is no brace event to pair it against, so its closing `while` is matched as soon as
    /// one is seen — which can swallow a genuine nested loop as if it were that `while`. This is
    /// not chased further, because doing so turns a token scanner into a parser (spec §24.4); it
    /// is closed instead by `scopeBreakers` refusing every unbraced loop body outright — see
    /// `loopSites`.
    static func loopOpeners(_ tokens: [Token]) -> [LoopOpener] {
        struct DoFrame { var closeDepth: Int; var satisfied: Bool }
        var out: [LoopOpener] = []
        var depth = 0
        var doStack: [DoFrame] = []
        for (i, t) in tokens.enumerated() {
            if t.kind == .punctuation {
                if t.text == "{" {
                    depth += 1
                } else if t.text == "}" {
                    depth -= 1
                    if let top = doStack.last, !top.satisfied, depth == top.closeDepth {
                        doStack[doStack.count - 1].satisfied = true
                    }
                }
                continue
            }
            guard t.kind == .identifier, !t.afterDot else { continue }
            switch t.text {
            case "for":
                out.append(LoopOpener(line: t.line, keywordIndex: i,
                                      braceIndex: bracedHeaderBraceIndex(tokens, headerStart: i + 1), isDo: false))
            case "do":
                let braced = i + 1 < tokens.count && tokens[i + 1].kind == .punctuation
                    && tokens[i + 1].text == "{"
                doStack.append(DoFrame(closeDepth: depth, satisfied: !braced))
                out.append(LoopOpener(line: t.line, keywordIndex: i, braceIndex: braced ? i + 1 : nil, isDo: true))
            case "while":
                if let top = doStack.last, top.satisfied {
                    doStack.removeLast()
                } else {
                    out.append(LoopOpener(line: t.line, keywordIndex: i,
                                          braceIndex: bracedHeaderBraceIndex(tokens, headerStart: i + 1), isDo: false))
                }
            default: break
            }
        }
        return out
    }

    /// The token index of the `{` that follows a parenthesized `( … )` header starting at
    /// `tokens[headerStart]` (tracking nested parens, so a call like `length(v)` inside a `for`'s
    /// condition doesn't close it early), or `nil` when the header is missing or unbraced.
    static func bracedHeaderBraceIndex(_ tokens: [Token], headerStart: Int) -> Int? {
        guard headerStart < tokens.count, tokens[headerStart].kind == .punctuation,
              tokens[headerStart].text == "(" else { return nil }
        var depth = 0
        var i = headerStart
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation {
                if t.text == "(" {
                    depth += 1
                } else if t.text == ")" {
                    depth -= 1
                    if depth == 0 {
                        let next = i + 1
                        if next < tokens.count, tokens[next].kind == .punctuation, tokens[next].text == "{" {
                            return next
                        }
                        return nil
                    }
                }
            }
            i += 1
        }
        return nil
    }
```

Delete `isBracedAfterParenthesizedHeader`. `scopeBreakers` (`where !opener.isBraced`) and `loopSites` (`.filter(\.isBraced).map(\.line)`) compile unchanged.

- [ ] **Step 3: Make the hardener a consumer**

In `LoopHardening.swift`, replace `loopBraceSites(in:)` (lines 158-214, doc comment included) with:

```swift
    /// The scanner's own loop openers — the same `do`/`while` pairing `scopeBreakers` and
    /// `loopSites` use, so the two can never disagree about where a loop is — narrowed to braced
    /// bodies and resolved to the character offsets hardening splices at. Before M9 this file
    /// carried a private mirror of that walk (spec §25.3, handoff §15.5 item 13).
    private static func loopBraceSites(in source: String) -> [Site] {
        let tokens = MSLScanner.tokenise(source)
        return MSLScanner.loopOpeners(tokens).compactMap { opener in
            guard let braceIndex = opener.braceIndex else { return nil }
            return makeSite(tokens, keywordIndex: opener.keywordIndex, braceIndex: braceIndex, isDo: opener.isDo)
        }
    }
```

Delete `bracedHeaderBraceIndex` from `LoopHardening.swift` (lines 301-330). `makeSite`, `needsWrapping`, `matchingCloseIndex`, `afterDoWhileSemicolon` stay: they are about *wrapping*, which only the hardener does. Update the file-level comment at lines 16-23 that says "see `loopBraceSites` below" — it still exists; no change needed there.

- [ ] **Step 4: Run the gate**

Run: `cd MetalNodesKit && swift test --filter "LoopHardeningTests|MSLScannerTests|CustomMSLDefinitionTests|ExpressionNodeTests|FormatCorpusTests"`
Expected: PASS — `hardeningOutputIsUnchangedByTheScannerFold` byte-identical, the compile-backed wrapping tests green through `MetalCompiler`. Then `grep -c "func bracedHeaderBraceIndex\|func loopBraceSites" Sources/MetalNodesCore/Codegen/*.swift` shows each name exactly once across the two files.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift MetalNodesKit/Sources/MetalNodesCore/Codegen/LoopHardening.swift MetalNodesKit/Tests/MetalNodesCoreTests/LoopHardeningTests.swift
git commit -m "refactor(hardening): LoopHardening consumes MSLScanner.loopOpeners instead of mirroring it"
```

---

### Task 7: Per-body scan cache (items 11, 12)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift` (`scopeBreakers`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift`

**Interfaces:**
- `scopeBreakers(in:)` keeps its signature; results for equal input are equal and now cached.

- [ ] **Step 1: Write the failing tests**

Append to `MSLScannerTests.swift`:

```swift
    /// Spec §25.3 (handoff §15.5 items 11–12): a debounced recompile re-scans every authored body;
    /// with the cache it re-pays only the edited one. Fifty 200-line bodies, scanned twice.
    @Test func repeatedScansOfTheSameBodiesAreServedFromTheCache() {
        let bodies = (0..<50).map { n in
            (0..<200).map { "float v\(n)_\($0) = in_a * \($0).0; // note" }.joined(separator: "\n")
        }
        let clock = ContinuousClock()
        let first = clock.measure { for b in bodies { _ = MSLScanner.scopeBreakers(in: b) } }
        let second = clock.measure { for b in bodies { _ = MSLScanner.scopeBreakers(in: b) } }
        #expect(second < first / 10, "first \(first), second \(second)")
    }

    /// Eviction never changes an answer: after more distinct bodies than the cache holds, the
    /// first body still scans correctly (it is simply recomputed).
    @Test func theCacheEvictsWithoutChangingResults() {
        let first = "out = 1.0;\nreturn;"
        let before = MSLScanner.scopeBreakers(in: first)
        for n in 0..<80 { _ = MSLScanner.scopeBreakers(in: "out = \(n).0;") }
        #expect(MSLScanner.scopeBreakers(in: first) == before)
        #expect(before == [MSLScanner.Violation(kind: .bareReturn, line: 1)])
    }
```

- [ ] **Step 2: Run them to verify the timing test fails**

Run: `cd MetalNodesKit && swift test --filter "repeatedScansOfTheSameBodiesAreServedFromTheCache|theCacheEvictsWithoutChangingResults"`
Expected: the timing test FAILS (second ≈ first); the eviction test passes (nothing to evict yet).

- [ ] **Step 3: Add the cache**

At the top of `MSLScanner.swift` add `import Synchronization`. Inside `MSLScanner`, before `scopeBreakers`:

```swift
    /// A bounded, insertion-ordered memo. Content-keyed, so a document reload needs no
    /// invalidation; bounded, so an editing session cannot grow it without limit (spec §25.3).
    struct ScanCache<Value> {
        let capacity: Int
        private var order: [String] = []
        private var values: [String: Value] = [:]

        init(capacity: Int) { self.capacity = capacity }

        mutating func value(for key: String, compute: () -> Value) -> Value {
            if let hit = values[key] { return hit }
            let v = compute()
            values[key] = v
            order.append(key)
            if order.count > capacity {
                values[order.removeFirst()] = nil
            }
            return v
        }
    }

    /// `scopeBreakers` memoised per body text. ~600 ns per character over three passes, re-paid on
    /// every debounced recompile for every authored body (handoff §15.5 item 11); with this only
    /// the edited body is scanned again. Sixty-four entries covers more definitions than any
    /// document has held; the lock is uncontended in practice (validation runs on one task).
    private static let scopeBreakerCache = Mutex(ScanCache<[Violation]>(capacity: 64))

    public static func scopeBreakers(in source: String) -> [Violation] {
        scopeBreakerCache.withLock { cache in
            cache.value(for: source) { uncachedScopeBreakers(in: source) }
        }
    }
```

Rename the existing `public static func scopeBreakers(in source: String)` body to `private static func uncachedScopeBreakers(in source: String) -> [Violation]` (its contents unchanged, including Task 4's `let source = normalisedLineEndings(source)` first line). `Violation` is already `Sendable`, which `Mutex` requires of its state; `ScanCache<[Violation]>` is a struct of `Sendable` parts.

- [ ] **Step 4: Run, then the mutation check**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter "MSLScannerTests|CustomCodeValidationTests"`
Expected: no warnings; PASS. Mutation: make `value(for:compute:)` always call `compute()`, confirm the timing test FAILS, restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift
git commit -m "perf(scanner): memoise scopeBreakers per body text in a bounded cache"
```

---

### Task 8: An edited, unwired geometry socket exports what the preview shows (item 5)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift:125-128, 164-165, 186-192`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift:225-243`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialExportTests.swift`

**Interfaces:**
- Produces: `MaterialCodegen.hasGeometryWork(_ geometry: Emitter.Output, terminal: NodeID, terminalNode: NodeInstance?, registry: NodeRegistry) -> Bool` (replaces the two-argument form) and a new `emitsGeometry: Bool` parameter on `MaterialCodegen.exportSource(...)`, computed once in `ShaderGenerator` and used for both the export text and `stageFunctionNames`.
- Consumes: `MetalCompiler.expectCompiles` (Task 1), `MaterialFixture.document` (in `MaterialValidationTests.swift`).

- [ ] **Step 1: Write the failing tests**

Append to `MaterialExportTests.swift`:

```swift
    /// Spec §25.2 (handoff §15.5 item 5): the preview applies an edited-but-unwired Position
    /// Offset; the export used to list it as baked and then emit no geometry stage at all.
    @Test func anEditedUnwiredPositionOffsetEmitsTheGeometryStage() throws {
        var doc = MaterialFixture.document()
        let terminal = try #require(doc.root.nodes.values.first { $0.kind == .builtin("output.material") }).id
        doc.root.nodes[terminal]!.params["positionOffset"] = .float3(.init(0, 1, 0))
        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let src = try #require(shader.exportSource)
        #expect(src.contains("realitykit::geometry_parameters params"))
        #expect(src.contains("geo.set_model_position_offset(float3(0.0, 1.0, 0.0));"))
        #expect(shader.stageFunctionNames[.geometry] != nil)
        try MetalCompiler.expectCompiles(src, extraArgs: ["-mmacosx-version-min=14.0"], "edited positionOffset")
    }

    @Test func anEditedUnwiredCustomAttributeEmitsTheGeometryStage() throws {
        var doc = MaterialFixture.document()
        let terminal = try #require(doc.root.nodes.values.first { $0.kind == .builtin("output.material") }).id
        doc.root.nodes[terminal]!.params["customAttribute"] = .float4(.init(0.25, 0.5, 0.75, 1))
        let src = try #require(ShaderGenerator.generate(doc, target: .realityKit).exportSource)
        #expect(src.contains("geo.set_custom_attribute(float4(0.25, 0.5, 0.75, 1.0));"))
    }

    /// The other direction is unchanged: a terminal at its defaults still emits no geometry stage,
    /// which is what keeps every corpus golden where it is.
    @Test func aDefaultUnwiredGeometrySocketStillEmitsNoGeometryStage() throws {
        let doc = MaterialFixture.document()
        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        #expect(shader.exportSource?.contains("realitykit::geometry_parameters") == false)
        #expect(shader.stageFunctionNames[.geometry] == nil)
    }
```

If the float4 literal in the second test is spelled differently by `ParamValues.mslLiteral` (run once and read the failure), copy the emitted spelling into the assertion — the point is the *presence* of the setter with the edited value.

- [ ] **Step 2: Run them to verify the two edited-value tests fail**

Run: `cd MetalNodesKit && swift test --filter "anEditedUnwired|aDefaultUnwiredGeometrySocket"`
Expected: the two edited-value tests FAIL (no geometry stage emitted); the default test passes.

- [ ] **Step 3: Widen the predicate and thread it through**

In `MaterialCodegen.swift` replace `hasGeometryWork` with:

```swift
    /// True when the geometry stage does anything but restate its defaults: some node reaches
    /// Position Offset or Custom Attribute, **or** the terminal's own unwired value for one of
    /// them has been edited away from its declared default. The preview always applies the
    /// terminal's value (`MaterialPreviewCodegen.vertexFunction` reads the same
    /// `inputExpressions`), so the export must too, or the header lists a value the shader never
    /// applies (spec §25.2, handoff §15.5 item 5). One predicate, read by the export text and by
    /// `stageFunctionNames`, so they cannot disagree.
    static func hasGeometryWork(_ geometry: Emitter.Output, terminal: NodeID,
                                terminalNode: NodeInstance?, registry: NodeRegistry) -> Bool {
        if geometry.lineOwners.contains(where: { $0 != nil && $0 != terminal }) { return true }
        guard let terminalNode, case .builtin(let id) = terminalNode.kind, let def = registry[id] else { return false }
        return liveGeometrySockets.contains { name in
            guard let decl = def.inputs.first(where: { $0.name == name }),
                  case .value(let dflt) = decl.default,
                  let edited = terminalNode.params[name] else { return false }
            return edited != dflt
        }
    }
```

Change `exportSource`'s signature to add `emitsGeometry: Bool` after `clearcoatNormalWired: Bool = false` (no default), and replace `if hasGeometryWork(geometry, terminal: terminal) {` at line 165 with `if emitsGeometry {`.

In `ShaderGenerator.swift`, before the `let export = MaterialCodegen.exportSource(` call, add:

```swift
        let emitsGeometry = MaterialCodegen.hasGeometryWork(exportGeometry, terminal: terminal,
                                                            terminalNode: doc.root.nodes[terminal], registry: registry)
```

pass `emitsGeometry: emitsGeometry` to `exportSource`, and replace `if MaterialCodegen.hasGeometryWork(exportGeometry, terminal: terminal) {` with `if emitsGeometry {`. `grep -rn "hasGeometryWork" Sources` must show only the definition and that one call.

- [ ] **Step 4: Run the material and corpus suites, then the mutation check**

Run: `cd MetalNodesKit && swift test --filter "MaterialExportTests|MaterialCodegenTests|CustomAttributeTests|FormatCorpusTests|LiveParametersTests"`
Expected: PASS, corpus goldens untouched (both RealityKit fixtures sit at the defaults). Mutation: make the new `guard let terminalNode …` branch `return false` unconditionally, confirm the two edited-value tests FAIL, restore.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift MetalNodesKit/Tests/MetalNodesCoreTests/MaterialExportTests.swift
git commit -m "fix(material): an edited, unwired geometry socket emits the geometry stage the preview already applies"
```

---

### Task 9: The node label column derives its width from the shape (item 8)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeGeometry.swift:10-48, 84-88`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/ParamControl.swift:6-20, 113, 175, 218`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift:33, 75-78, 87, 285-288`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift:108-111, 121-125`, `Editor/InspectorView+Groups.swift:58-61`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/NodeGeometryTests.swift`

**Interfaces:**
- Produces: `NodeGeometry.baseWidth: CGFloat` (190, the old `width`), `NodeGeometry.width` kept as an alias for canvas placement math, `NodeGeometry.minLabelColumn` (46), `NodeGeometry.maxLabelColumn` (120), `NodeGeometry.labelColumnWidth(for shape: NodeShape) -> CGFloat`, `NodeGeometry.width(for shape: NodeShape) -> CGFloat`. `ParamControl` gains `var labelWidth: CGFloat = NodeGeometry.minLabelColumn`.

- [ ] **Step 1: Write the failing tests**

Append to `NodeGeometryTests.swift`:

```swift
    /// Spec §25.2 (handoff §15.5 item 8): the label column is derived per shape from its longest
    /// row label, and the node widens by the same amount, so "Roughness" and "Clearcoat
    /// Roughness" sit on one line and a row never grows taller than its one allotted row.
    @Test func theLabelColumnGrowsWithTheLongestRowLabel() throws {
        let float = try #require(reg["input.float"])
        #expect(NodeGeometry.labelColumnWidth(for: NodeShape(def: float)) == NodeGeometry.minLabelColumn)
        let material = try #require(reg["output.material"])
        let column = NodeGeometry.labelColumnWidth(for: NodeShape(def: material))
        #expect(column > NodeGeometry.minLabelColumn)
        #expect(column <= NodeGeometry.maxLabelColumn)
        #expect(column >= CGFloat("Clearcoat Roughness".count) * 5.5, "wide enough for the longest label at caption size")
    }

    @Test func theNodeWidensByExactlyTheExtraColumn() throws {
        let material = NodeShape(def: try #require(reg["output.material"]))
        let column = NodeGeometry.labelColumnWidth(for: material)
        #expect(NodeGeometry.estimatedSize(for: material).width == NodeGeometry.baseWidth + column - NodeGeometry.minLabelColumn)
        #expect(NodeGeometry.estimatedSize(for: material).height
                == NodeGeometry.headerHeight + NodeGeometry.bodyPadding + CGFloat(NodeGeometry.bodyRows(material)) * NodeGeometry.rowHeight)
    }

    @Test func outputAnchorsSitOnTheWidenedRightEdge() throws {
        let sep = try #require(reg["vector.separate"])
        let material = try #require(reg["output.material"])
        var g = Graph()
        let m = NodeInstance(kind: .builtin(material.id), position: CGPoint(x: 10, y: 20))
        let s = NodeInstance(kind: .builtin(sep.id), position: CGPoint(x: 300, y: 20))
        g.nodes[m.id] = m; g.nodes[s.id] = s
        let doc = document(root: g)
        let sepOut = try #require(NodeGeometry.socketAnchor(for: SocketRef(s.id, "x"), in: g, shapes: rootShapes(doc)))
        #expect(sepOut.x == 300 + NodeGeometry.width(for: NodeShape(def: sep)))
        #expect(NodeGeometry.width(for: NodeShape(def: sep)) == NodeGeometry.baseWidth)
        #expect(NodeGeometry.width(for: NodeShape(def: material)) > NodeGeometry.baseWidth)
    }
```

- [ ] **Step 2: Run them to verify they fail to compile**

Run: `cd MetalNodesKit && swift test --filter NodeGeometryTests`
Expected: build error — `labelColumnWidth`, `baseWidth`, `width(for:)` do not exist.

- [ ] **Step 3: Derive the width in `NodeGeometry`**

Replace `static let width: CGFloat = 190` with:

```swift
    /// A node's width with the narrowest label column. Canvas placement (`GraphCanvasView`)
    /// centres new nodes on this; a node's real width is `width(for:)`.
    static let baseWidth: CGFloat = 190
    static var width: CGFloat { baseWidth }
    /// The label column every one-line body row shares: `ParamControl`'s `frame(width:)`.
    static let minLabelColumn: CGFloat = 46
    /// Wide enough for "Clearcoat Roughness" at `.caption` size; nothing in the library is longer.
    static let maxLabelColumn: CGFloat = 120
    /// An estimate of `.caption`'s average advance, rounded up so it errs wide: a label that
    /// wraps is the defect (handoff §15.3.1), a column a few points too wide is not.
    static let captionPointsPerCharacter: CGFloat = 6.4

    /// The label column for `shape`'s body rows — inputs and body params, the two row kinds that
    /// draw a leading label — from its longest label. One function, two readers: `NodeView`
    /// passes it to every `ParamControl`, and `estimatedSize` widens the node by the same amount,
    /// so the estimate and the drawing cannot disagree (spec §25.2, handoff §15.5 item 8).
    static func labelColumnWidth(for shape: NodeShape) -> CGFloat {
        let labels = shape.inputs.map(\.label) + shape.params.filter(\.showsInBody).map(\.label)
        let longest = labels.map(\.count).max() ?? 0
        return min(maxLabelColumn, max(minLabelColumn, (CGFloat(longest) * captionPointsPerCharacter).rounded(.up)))
    }

    static func width(for shape: NodeShape) -> CGFloat {
        shape.style == .dot ? dotSize : baseWidth + labelColumnWidth(for: shape) - minLabelColumn
    }
```

In `estimatedSize(for:)` replace `CGSize(width: width, …` with `CGSize(width: width(for: shape), …`. In `socketAnchor` replace `x: node.position.x + width` with `x: node.position.x + width(for: shape)`. Leave `GraphCanvasView`'s four `NodeGeometry.width / 2` uses as they are (they centre a new node on the base width).

- [ ] **Step 4: Thread the width into the rows**

`ParamControl.swift`: add `var labelWidth: CGFloat = NodeGeometry.minLabelColumn` after `var onChooseImage: ((ImageSource) -> Void)? = nil`, and change the three `.frame(width: 46, alignment: .leading)` (lines 113, 175, 218) to `.frame(width: labelWidth, alignment: .leading)`.

`NodeView.swift`: delete `static let width: CGFloat = NodeGeometry.width` (line 33); change `.frame(width: Self.width)` (line 87) to `.frame(width: NodeGeometry.width(for: shape))`; in both `ParamControl(` initialisers (lines 75-78 and 285-288) add `labelWidth: NodeGeometry.labelColumnWidth(for: shape),` as the argument right after `kind:`. Search the file for any other `Self.width` and replace the same way.

`InspectorView.swift` (lines 108 and 121) and `InspectorView+Groups.swift` (line 58): add the same `labelWidth: NodeGeometry.labelColumnWidth(for: shape),` argument — the inspector's rows wrapped exactly like the node's. Confirm each site has `shape` in scope (`InspectorView.swift:97` reads `shape.inputs`; in `InspectorView+Groups.swift` check the enclosing function's parameters and use its shape variable's name).

- [ ] **Step 5: Run the UI suite and build**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter "NodeGeometryTests|EditorModelTests|MinimapLayoutTests|WireGeometryTests"`
Expected: no warnings; PASS. `estimatedSizeCountsRows` still sees width 190 for `vector.separate`. Mutation: make `labelColumnWidth` return `minLabelColumn` always, confirm the three new tests FAIL, restore.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesUI MetalNodesKit/Tests/MetalNodesUITests/NodeGeometryTests.swift
git commit -m "fix(canvas): the node label column derives its width from the shape's longest label"
```

---

### Task 10: ⌘Z in a focused text view forwards down the responder chain, macOS (item 9)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift:1-2, 41-72`

**Interfaces:**
- No new API. The Undo/Redo `Button`s' actions and `disabled` conditions change on macOS only.

Verified live, not by a unit test (spec §25.2): SwiftUI `Commands` cannot be constructed in a test and the field editor's response is AppKit's. The live check is Task 13's.

- [ ] **Step 1: Forward when a text view is first responder**

At the top of `EditorCommands.swift` add, after `import SwiftUI`:

```swift
#if canImport(AppKit)
import AppKit
#endif
```

Replace the `CommandGroup(replacing: .undoRedo) { … }` block (and the long comment above it that begins `// Undo/Redo, Delete, and the View menu's bare-key shortcuts are gated` — keep that comment's first paragraph about `canvasHasFocus`, replace everything from `// DELIBERATELY still \`canvasFocused\` alone` to the end of the block) with:

```swift
        // macOS (spec §25.2, handoff §15.5 item 9): the items stay enabled, and the *action*
        // decides. With a text view as first responder — a node parameter field, the inspector's
        // formula field, the code editor — ⌘Z is forwarded down the responder chain as `undo:`,
        // so the field editor's own text undo fires; nothing reaches the model, which is what
        // keeps ruling 26's data-loss path closed (a document undo can never reseed the code
        // editor's draft mid-keystroke, because it is never called from here while one is
        // focused). Otherwise the document undo runs exactly as before, gated on the canvas.
        // Before M9 the items were *disabled* while a field was focused, and a disabled menu item
        // swallows its key equivalent — ⌘Z did nothing at all inside any text view.
        //
        // iPadOS keeps the pre-M9 gating (recorded as unverified in handoff §16): UIKit's text
        // views route ⌘Z through their own key commands, and this milestone verifies macOS only.
        CommandGroup(replacing: .undoRedo) {
            Button(model?.undoManager.undoMenuItemTitle ?? "Undo") { undoCommand() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoDisabled)
            Button(model?.undoManager.redoMenuItemTitle ?? "Redo") { redoCommand() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoDisabled)
        }
```

and add these members to `EditorCommands` (after `canvasFocusedOrEditingCode`):

```swift
    #if os(macOS)
    /// True while an AppKit text view (a `TextField`'s field editor, a `TextEditor`'s `NSTextView`)
    /// is the key window's first responder. `NSTextView` is an `NSText`, so one check covers both.
    private var textViewIsFirstResponder: Bool { NSApp.keyWindow?.firstResponder is NSText }
    private var undoDisabled: Bool { model == nil }
    private var redoDisabled: Bool { model == nil }

    private func undoCommand() {
        if textViewIsFirstResponder { _ = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        if canvasFocused, model?.canUndo == true { model?.undo() }
    }

    private func redoCommand() {
        if textViewIsFirstResponder { _ = NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        if canvasFocused, model?.canRedo == true { model?.redo() }
    }
    #else
    private var undoDisabled: Bool { !((model?.canUndo ?? false) && canvasFocused) }
    private var redoDisabled: Bool { !((model?.canRedo ?? false) && canvasFocused) }
    private func undoCommand() { model?.undo() }
    private func redoCommand() { model?.redo() }
    #endif
```

`EditorCommands` is a `Commands` struct in a module whose default isolation is `MainActor`, so `NSApp` is reachable without further annotation.

- [ ] **Step 2: Build both platforms warning-free**

Run (from the repo root):
```bash
cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; cd ..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS' build -quiet 2>&1 | grep -E "warning:|error:"
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```
Expected: nothing printed by either grep.

- [ ] **Step 3: Run the UI suite (the menu is not covered, the rest must stay green)**

Run: `cd MetalNodesKit && swift test --filter "EditorUndoTests|EditorUndoInjectionTests|CustomCodeEditorTests|ExpressionEditorTests"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift
git commit -m "fix(commands): ⌘Z and ⇧⌘Z forward to a focused text view on macOS instead of sitting disabled"
```

---

### Task 11: The deferred-item sweep (T3, T4, T6, T9, T11, T14)

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift:92-100` (comment), `Emitter.swift:236-241`, `CustomCodeValidation.swift:14-19`, `EmitEnvironment.swift` (new method), `ShaderGenerator.swift:213-217`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LibraryM3Tests.swift:12-23`, `MSLScannerTests.swift`, `GroupOperationsTests.swift`, `CustomCodeValidationTests.swift`, `EmitEnvironmentTests.swift`, `ExpressionNodeTests.swift:87, 105, 127, 139, 148, 183`, `CustomAttributeTests.swift:41-53`

**Interfaces:**
- Produces: `EmitEnvironment.withUniformSpeller(_ uniform: @escaping @Sendable (UniformField) -> String) -> EmitEnvironment` (public), used by `ShaderGenerator`'s `bake`.

Handoff §15.5's T10 (`table[c]!`) is already absent from `EmitEnvironment.swift` — verify with `grep -n '\]!' Sources/MetalNodesCore/Codegen/EmitEnvironment.swift` (prints nothing) and record that in the report; no change. T6's "dead `layer` handling" is likewise already gone from `mslNameCollides`; only its `.input` test is owed.

- [ ] **Step 1: T3 — the library sweep actually wires the Expression node**

In `LibraryM3Tests.everyNodeGeneratesAsAOneNodeGraph` replace the loop body's first three lines with:

```swift
            var doc = ShaderDocument()
            var n = NodeInstance(kind: .builtin(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
            // The Expression registry entry declares no outputs — its shape is computed from the
            // formula — so without one it was the only node this sweep never wired (handoff T3).
            if def.id == ExpressionNode.id { n.params[ExpressionNode.formulaParam] = .text("a") }
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            let outName = def.id == ExpressionNode.id ? "out" : def.outputs.first?.name
            if let outName { doc.root.connect(SocketRef(n.id, outName), to: SocketRef(out.id, "color")) }
```

Run `swift test --filter everyNodeGeneratesAsAOneNodeGraph` — PASS. Mutation: set the formula to `.text("")`, confirm the sweep still passes (an empty formula emits `0.0`), then set it to `.text("a +")` and confirm it FAILS on a Metal-level placeholder or throws — either proves the node is now on the path; restore `"a"`.

- [ ] **Step 2: T4 — comment and the repeated-occurrence test**

In `MSLScanner.swift`'s `rewritingIdentifiers` doc comment, change `only a *bound* \`col\` before the dot is ever a candidate` to `only a *free* \`col\` before the dot is ever a candidate`. Append to `MSLScannerTests.swift`:

```swift
    @Test func everyOccurrenceOfAFreeIdentifierIsRewritten() {
        #expect(MSLScanner.rewritingIdentifiers(in: "a * a + sin(a)") { "{\($0)}" } == "{a} * {a} + sin({a})")
    }
```

- [ ] **Step 3: T6 — the `.input` branch of the reserved-name check**

Append to `GroupOperationsTests.swift`:

```swift
    /// The `.input` branch of `mslNameCollides` had no test (handoff T6): an input named `x`
    /// would be spelled `in_x` inside the body, which collides with an *output* already named
    /// `in_x` — the mirror of the output-side check.
    @Test func anInputWhosePrefixedNameMatchesAnOutputIsReserved() {
        var def = GroupDefinition(name: "W")
        def.body = .msl("out = 1.0;")
        def.outputs = [SocketDecl(name: "in_x", type: .concrete(.float))]
        #expect(GroupOperations.mslReservedSocketName("x", kind: .input, in: def))
        #expect(!GroupOperations.mslReservedSocketName("y", kind: .input, in: def))
    }

    @Test func aGraphDefinitionReservesNoMSLNames() {
        let def = GroupDefinition(name: "G")
        #expect(!GroupOperations.mslReservedSocketName("uv", kind: .output, in: def))
    }
```

`GroupDefinition(name:)`'s body defaults to `.graph` (Task 4's `definitionDoc` helper relies on the same initialiser).

- [ ] **Step 4: T9 — no trap in release, and the validator scans what codegen maps**

In `Emitter.swift` replace:

```swift
                    precondition(lines.count == templated.userLines.count,
                                "Expression template's line count must match its userLines origins")
                    lineOrigins = templated.userLines.map { .user($0) }
```

with:

```swift
                    // Provably equal today (substitution never adds or removes a newline). Were a
                    // future placeholder ever to span lines, a wrong origin map is a worse-located
                    // diagnostic; a trap in a release build is a crash on the user's document.
                    // So: fall back to "generated" for every line rather than assert (handoff T9).
                    lineOrigins = lines.count == templated.userLines.count
                        ? templated.userLines.map { .user($0) }
                        : Array(repeating: .generated, count: lines.count)
```

In `CustomCodeValidation.diagnostics`, the Expression loop: replace `out += MSLScanner.scopeBreakers(in: formula).map {` with

```swift
            // The same text codegen maps: `ExpressionNode.template` trims the formula before
            // hardening, so a formula with leading newlines would otherwise report a line number
            // one path apart from the compile error's (handoff T9).
            let scanned = formula.trimmingCharacters(in: .whitespacesAndNewlines)
            out += MSLScanner.scopeBreakers(in: scanned).map {
```

Append to `CustomCodeValidationTests.swift`:

```swift
    /// The validator and codegen count the same lines: both trim the formula first (handoff T9).
    @Test func aFormulaWithLeadingNewlinesReportsTheTrimmedLine() {
        let d = CustomCodeValidation.diagnostics(document: expressionDoc("\n\nreturn a;"), registry: .builtin)
        #expect(d.count == 1)
        #expect(d.first?.userLine == 1)
    }
```

- [ ] **Step 5: T11 — `bake` keeps `knownAccessors`**

In `EmitEnvironment.swift`, after the `init`, add:

```swift
    /// This environment with only its uniform speller replaced: every other field — `sys`,
    /// texture spelling, `usesLayer`, `knownAccessors` — carried through. `ShaderGenerator`'s
    /// export path used to rebuild the environment by hand and silently dropped
    /// `knownAccessors` (handoff T11); a copy that names no field cannot lose one.
    public func withUniformSpeller(_ uniform: @escaping @Sendable (UniformField) -> String) -> EmitEnvironment {
        var copy = self
        copy.uniform = uniform
        return copy
    }
```

If `uniform` is declared `let`, change it to `public var uniform` (check line ~30). In `ShaderGenerator.swift` replace the nested `func bake(_ env: EmitEnvironment) -> EmitEnvironment { EmitEnvironment(uniform: baked, sys: env.sys, textureSample: env.textureSample, textureName: env.textureName, usesLayer: env.usesLayer) }` with `func bake(_ env: EmitEnvironment) -> EmitEnvironment { env.withUniformSpeller(baked) }`. Append to `EmitEnvironmentTests.swift`:

```swift
    @Test func replacingTheUniformSpellerKeepsEveryOtherField() {
        let env = EmitEnvironment.realityKitSurface
        let baked = env.withUniformSpeller { _ in "1.0" }
        #expect(baked.knownAccessors == env.knownAccessors)
        #expect(!baked.knownAccessors.isEmpty)
        #expect(baked.sys.keys.sorted() == env.sys.keys.sorted())
        #expect(baked.usesLayer == env.usesLayer)
    }
```

- [ ] **Step 6: T14 — structural assertions**

In `ExpressionNodeTests.swift` add a file-private helper at the top of the suite:

```swift
    /// `Emitter` names SSA variables `v0, v1, …` per stage; which number a node lands on depends
    /// on emission order, not on the assertion's subject. Match the statement's shape, not `v0`.
    private func emits(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
```

and change the six assertions:

| Line | Before | After |
|---|---|---|
| 87 | `#expect(s.contains("v0 = float4(u.p0, 0.0, 0.0, 1.0);"))` | `#expect(emits(s, #"\bv\d+ = float4\(u\.p0, 0\.0, 0\.0, 1\.0\);"#))` |
| 105 | `#expect(s.contains("v0 = u.p0 + 1.0;"))` | `#expect(emits(s, #"\bv\d+ = u\.p0 \+ 1\.0;"#))` |
| 106 (`return v0;`) | `#expect(s.contains("return v0;"))` | `let name = try #require(s.firstMatch(of: /(v\d+) = u\.p0 \+ 1\.0;/)?.1); #expect(s.contains("return \(name);"))` |
| 127 | `#expect(s.contains("v0 = in.uv;"))` | `#expect(emits(s, #"\bv\d+ = in\.uv;"#))` |
| 139 | `#expect(s.contains("v0 = float4(u.p0.rgb, 1.0);"))` | `#expect(emits(s, #"\bv\d+ = float4\(u\.p0\.rgb, 1\.0\);"#))` |
| 148 | `#expect(s.contains("v0 = u.p0 + u.p1.a;"))` | `#expect(emits(s, #"\bv\d+ = u\.p0 \+ u\.p1\.a;"#))` |
| 183 | `#expect(s.contains("v0 = saturate(u.p0);"))` | `#expect(emits(s, #"\bv\d+ = saturate\(u\.p0\);"#))` |

In `CustomAttributeTests.swift` replace the two `v0` assertions:

```swift
    @Test func theExportWritesInGeometryAndReadsInSurface() throws {
        let src = try #require(ShaderGenerator.generate(document(), target: .realityKit).exportSource)
        // Whichever SSA name the colour node lands on, the setter must name *that* variable.
        let name = try #require(src.firstMatch(of: /(v\d+) = float4\(1\.0, 0\.0, 0\.0, 1\.0\);/)?.1)
        #expect(src.contains("geo.set_custom_attribute(\(name))"))
        #expect(src.contains("params.geometry().custom_attribute()"))
    }

    @Test func thePreviewCarriesItAsAnInterpolant() throws {
        let src = try ShaderGenerator.generate(document(), target: .realityKit).source
        #expect(src.contains("float4 customAttribute;"))
        let name = try #require(src.firstMatch(of: /(v\d+) = float4\(1\.0, 0\.0, 0\.0, 1\.0\);/)?.1)
        #expect(src.contains("o.customAttribute = \(name);"))
        #expect(src.contains("in.customAttribute"))
    }
```

Bare `/…/` regex literals are on by default in Swift 6 language mode; `.1` is the first capture as `Substring`, and string interpolation of a `Substring` is fine.

- [ ] **Step 7: Run everything touched**

Run: `cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; swift test --filter "LibraryM3Tests|MSLScannerTests|GroupOperationsTests|CustomCodeValidationTests|EmitEnvironmentTests|ExpressionNodeTests|CustomAttributeTests|MaterialExportTests|FormatCorpusTests"`
Expected: no warnings; PASS. Mutations, one each: (T9) put the `precondition` back and pass a two-line `userLines` — not reachable; instead confirm `aFormulaWithLeadingNewlinesReportsTheTrimmedLine` FAILS when `scanned` is replaced by `formula`. (T11) make `withUniformSpeller` drop `knownAccessors` (`copy.knownAccessors = []`), confirm `replacingTheUniformSpellerKeepsEveryOtherField` FAILS. Restore both.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources MetalNodesKit/Tests
git commit -m "chore(core): the M9 sweep — Expression in the library sweep, no release trap, bake keeps knownAccessors, structural SSA assertions"
```

---

### Task 12: iOS 26.0 floor and Metal validation on the test scheme (items 16, 3)

**Files:**
- Modify: `MetalNodesKit/Package.swift:6`
- Modify: `MetalNodes.xcodeproj/project.pbxproj` — exactly the four `IPHONEOS_DEPLOYMENT_TARGET = 27.0;` lines (264, 328, 428, 457)
- Modify: `MetalNodes.xcodeproj/xcshareddata/xcschemes/MetalNodes.xcscheme:25-42`

- [ ] **Step 1: Lower the floor**

In `Package.swift` change `platforms: [.macOS("26.0"), .iOS("27.0")]` to `platforms: [.macOS("26.0"), .iOS("26.0")]`. Then:

```bash
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 27.0;/IPHONEOS_DEPLOYMENT_TARGET = 26.0;/' MetalNodes.xcodeproj/project.pbxproj
git diff --stat MetalNodes.xcodeproj/project.pbxproj
git diff MetalNodes.xcodeproj/project.pbxproj | grep '^[-+]' | grep -v '^[-+][-+]'
```

Expected: `1 file changed, 4 insertions(+), 4 deletions(-)` and eight lines, all `IPHONEOS_DEPLOYMENT_TARGET`. Any other line means Xcode rewrote the file: `git checkout -- MetalNodes.xcodeproj/project.pbxproj` and redo the `sed` with Xcode closed.

- [ ] **Step 2: Build both platforms under Xcode 26.6**

```bash
cd MetalNodesKit && swift build 2>&1 | grep -E "warning:|error:"; cd ..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS' build -quiet 2>&1 | grep -E "warning:|error:"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build -quiet 2>&1 | grep -E "warning:|error:"
git diff --stat MetalNodes.xcodeproj/project.pbxproj
```

Expected: every grep prints nothing (the five deployment-target warnings are gone); the pbxproj diff is still exactly 4/4. If `xcodebuild` added lines, `git checkout --` the file, re-apply the `sed`, and build again with Xcode itself closed.

- [ ] **Step 3: `MTL_DEBUG_LAYER=1` on the test action**

In `MetalNodes.xcscheme`, change `shouldUseLaunchSchemeArgsEnv = "YES"` on `<TestAction` to `"NO"`, and insert, immediately after the `<TestAction … >` opening tag's closing `>` and before `<Testables>`:

```xml
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "MTL_DEBUG_LAYER"
            value = "1"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
```

Deviation from spec §25.5, recorded here: the scheme's test action holds only `MetalNodesAppUITests`, so this variable reaches the UI-test run; the package's GPU tests run under `swift test`, where the variable is the shell's. Verify the mechanism itself with the package tests:

```bash
cd MetalNodesKit && MTL_DEBUG_LAYER=1 swift test --filter MetalNodesRenderTests 2>&1 | grep -iE "validation|Test run with"
```

Expected: a `Metal API Validation Enabled` line from the first device creation, and the Render suite still `passed`. Record the exact line in the report. Add one sentence to `README.md` (or, if there is none, to the handoff §16 draft) : `Run GPU tests with MTL_DEBUG_LAYER=1 swift test to turn the Metal validation layer on locally; the shared scheme's test action sets it for xcodebuild.`

- [ ] **Step 4: Commit — the one deliberate project-file commit**

```bash
git add MetalNodesKit/Package.swift MetalNodes.xcodeproj/project.pbxproj MetalNodes.xcodeproj/xcshareddata/xcschemes/MetalNodes.xcscheme
git commit -m "build: iOS deployment floor 26.0 to match the Xcode Cloud toolchain; MTL_DEBUG_LAYER=1 on the test scheme"
```

---

### Task 13: Execution record, live checks, memory (controller)

**Files:**
- Modify: `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` (new §16), `docs/superpowers/specs/2026-09-04-metalnodes-design.md` §25 (amendments if any ruling deviated)

Run by the controller after the final whole-branch review, with the app built and the screen unlocked.

- [ ] **Step 1: The four live checks (spec §25.6)**

Build and launch the Debug app (`DEVELOPER_DIR=… xcodebuild … -destination 'platform=macOS' build`, then `open` the product; `git checkout -- MetalNodes.xcodeproj/project.pbxproj`). Then:

1. **Item 8** — new document, Target → RealityKit Material, add a Material Output: every socket label ("Roughness", "Ambient Occlusion", "Clearcoat Roughness") on one line, node visibly wider, wires still land on the dots.
2. **Item 9** — Expression node, click the inspector's Formula field, type `zz`, ⌘Z: the two characters disappear and the cursor stays. Click the empty canvas, ⌘Z: the last document step reverts (Edit ▸ Undo names it). Open a Custom Code definition, type, ⌘Z inside: text undo; ⌘↑ then ⌘Z: the body commit reverts.
3. **Item 7** — Material Output's Roughness slider: dragging to either end shows 0.00 and 1.00, never −10.
4. **Item 4** — set the UV node's Mode to Aspect under RealityKit: the strip ends with "or switch this node's Mode to Normalized".

- [ ] **Step 2: Write handoff §16**

Sections, mirroring §15: 16.1 what shipped (one line per task, commit hashes); 16.2 rulings (every `Ruling:` line from the ledger, including the Task 12 scheme deviation); 16.3 the four live checks with results, plus the iPad ⌘Z behaviour recorded as unverified; 16.4 what the reviews caught; 16.5 the M10 starting list — the timeline-and-recording feature (§17 Q4) as the milestone, and anything M9 left (per-task items T2, T5, T8; the Custom Code deferrals; item 26/36/39–41 still owed on a device).

- [ ] **Step 3: Update memory and commit**

Update `metalnodes-project-state.md` (M9 merged, test count, M10 = timeline) and the MEMORY.md index line; commit the handoff with the standard trailers.

---

## Self-review

**Spec coverage.** §25.2: item 4 → Task 2; item 5 → Task 8; item 6 → Task 4; item 7 → Task 3; item 8 → Task 9; item 9 → Task 10; item 10 withdrawn (no task). §25.3: item 13 → Task 6; item 14 → Task 5; items 11–12 → Task 7. §25.4: item 15 → Task 1; T3/T4/T6/T9/T11/T14 → Task 11 (T10 verified absent, recorded there). §25.5: item 16 and item 3 → Task 12, with the scheme deviation stated in the task. §25.6: mutation checks in every task, corpus in Tasks 2/3/4/5/6/8/11, `xcrun metal` through Task 1's helper, the four live checks and both `xcodebuild`s in Tasks 10/12/13.

**Placeholder scan.** No TBD/TODO. Every code step carries code. Task 1's table lists sites by line with the exact before/after pattern shown once; Task 9's "check the enclosing function's parameters" in `InspectorView+Groups.swift` is a real instruction, not a placeholder — the variable name at that site was not verified when this plan was written, and the implementer must read it.

**Type consistency.** `MetalCompiler.expectCompiles(_:extraArgs:_:sourceLocation:)` is used by Tasks 6 (via `LoopHardeningTests.compiles`, which calls `compile`) and 8 (`expectCompiles`); `MSLScanner.LoopOpener.braceIndex: Int?` / `keywordIndex: Int` / `isDo: Bool` are what Task 6's `LoopHardening` consumes; `NodeGeometry.baseWidth` / `minLabelColumn` / `maxLabelColumn` / `labelColumnWidth(for:)` / `width(for:)` match between Task 9's tests and implementation; `MaterialCodegen.hasGeometryWork(_:terminal:terminalNode:registry:)` and `exportSource(… emitsGeometry:)` match between Task 8's two files; `EmitEnvironment.withUniformSpeller(_:)` matches between Task 11's source and test. `liveGeometrySockets` exists at `MaterialCodegen.swift:92`. `Emitter.LineOrigin.generated` exists. `SocketKind.input/.output` exist. `MaterialFixture.wire` is `@discardableResult` and returns `NodeID`.
