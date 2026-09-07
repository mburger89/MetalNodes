# MetalNodes M8 — Custom Code, One Legality Predicate, RealityKit Follow-ups

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users write their own shader code — a one-line Expression node and a reusable Custom MSL definition — retire the four-way legality seam behind a single predicate, and finish the three RealityKit features M7 deferred.

**Architecture:** Both new node kinds reuse paths that already exist rather than adding codegen. An Expression node is a builtin whose body template comes from the document instead of the library, so it inlines through `Emitter.substitute` like every other builtin; a Custom MSL node is a `GroupDefinition` whose body is text instead of a graph, so it emits one function called once per instance exactly as groups do. Legality stops being three static sets and becomes a question asked of the emit environment's own vocabulary.

**Tech Stack:** Swift 6.4 (strict concurrency), SwiftUI, Metal / MetalKit, Swift Testing, SwiftPM package `MetalNodesKit` (targets `MetalNodesCore`, `MetalNodesRender`, `MetalNodesUI`) plus the app target `MetalNodes`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §24 is this milestone. §8 (node definitions), §9 (codegen), §20 (groups), §21 (persistence/UI) and §23 (RealityKit) are the machinery it extends.

## Global Constraints

- **Swift 6.4, strict concurrency, warning-free.** `swift build --package-path MetalNodesKit` must emit no warning lines. Public API in `MetalNodesCore` is `Sendable` value types; `MetalNodesCore` imports no AppKit/UIKit/Metal.
- **Never commit `MetalNodes.xcodeproj/project.pbxproj`.** Xcode rewrites it on open/build; run `git checkout -- MetalNodes.xcodeproj/project.pbxproj` after any `xcodebuild`, and check `git status` before committing.
- **Xcode Cloud builds with Xcode 26.6**, not the local Xcode 27. Reproduce a cloud failure with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`.
- **No existing golden source may change.** The fragment, three stitchable, and RealityKit targets all have golden tests. A changed golden is a defect in your change, not a test to rebaseline — except where a task explicitly says a golden moves and why.
- **Every M0–M7 document must still open.** `GroupDefinition` gains a sum-type body and `DocumentSettings` gains a field; both decode with fallbacks. A document that fails to open is the worst defect this milestone can ship.
- **The user's text is never rewritten.** Guards refuse or codegen hardens the *emitted* MSL; what the editor shows is always exactly what the user typed (spec §24.4).
- Test command: `swift test --package-path MetalNodesKit`. One suite: `swift test --package-path MetalNodesKit --filter <SuiteName>`.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```

---

## File Structure

**Created — `MetalNodesCore`:**

| File | Responsibility |
|---|---|
| `Sources/MetalNodesCore/Codegen/MSLScanner.swift` | The token scan: identifiers, keyword/builtin filtering, scope-breaker guards, loop sites. Pure, no dependencies, heavily tested — every other custom-code feature asks it questions. |
| `Sources/MetalNodesCore/Library/Builtin/ExpressionNode.swift` | `utility.expression` and its formula→sockets derivation |
| `Sources/MetalNodesCore/Codegen/LoopHardening.swift` | Rewrites emitted loop text to carry an iteration cap |

**Created — tests:** `MSLScannerTests.swift`, `ExpressionNodeTests.swift`, `CustomMSLDefinitionTests.swift`, `LoopHardeningTests.swift`, `LegalityPredicateTests.swift`, `LiveParametersTests.swift`, `ClearcoatTests.swift`, `CustomAttributeTests.swift` (Core); `UserLineErrorTests.swift`, `CustomCodeCompileTests.swift` (Render); `ExpressionEditorTests.swift` (UI).

**Modified:**

| File | Change |
|---|---|
| `MetalNodesCore/ParamValue.swift` | `case text(String)`; `socketType` returns `nil` for it |
| `MetalNodesCore/NodeDef.swift` | `ParamKind.text`; later, `stages` becomes derived |
| `MetalNodesCore/NodeShape.swift` | Expression's shape computed from its formula |
| `MetalNodesCore/ShaderDocument.swift` | `DefinitionBody`; `DocumentSettings.liveParameters` |
| `MetalNodesCore/Groups/GroupCodegen.swift` | Emit a `.msl` body |
| `MetalNodesCore/Codegen/LineMap.swift` | `userLineOffset` |
| `MetalNodesCore/Codegen/EmitEnvironment.swift` | `SysValue`, `canEmit` |
| `MetalNodesCore/Codegen/MaterialValidation.swift` | Call the predicate instead of static sets |
| `MetalNodesCore/Codegen/MaterialCodegen.swift` | Clearcoat setters; live-parameter spelling |
| `MetalNodesCore/Codegen/MaterialPreviewCodegen.swift` | Clearcoat lobe; `customAttribute` interpolant |
| `MetalNodesCore/Library/Builtin/Material3DNodes.swift` | Clearcoat + customAttribute sockets and node |
| `MetalNodesCore/Export/MaterialExport.swift` | Live parameters; the clearcoat availability note |
| `MetalNodesUI/Editor/InspectorView.swift` | Formula field; live-parameter marking |
| `MetalNodesUI/Editor/CodePanel.swift` | Editable variant for a `.msl` definition |
| `MetalNodesUI/Editor/EditorModel.swift` | Diagnostics carry a user line |

---

### Task 1: A text parameter

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ParamValue.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift` (`ParamKind`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ParamValueTests.swift` (append; create if absent)

**Interfaces:**
- Produces: `ParamValue.text(String)` and `ParamKind.text`. `ParamValue.text.socketType == nil`, so `isUniformable` is false and it never claims a uniform slot.
- Consumes: nothing.

A formula is text, and `ParamValue` has no case for it. This is the smallest possible foundation and everything else builds on it.

- [ ] **Step 1: Write the failing test**

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/ParamValueTests.swift`:

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct TextParamValueTests {
    @Test func textRoundTripsThroughCoding() throws {
        let v = ParamValue.text("sin(a * 6.28) * b")
        let back = try JSONDecoder().decode(ParamValue.self, from: try JSONEncoder().encode(v))
        #expect(back == v)
    }

    /// A formula is never a uniform: it has no socket type, so the layout builder skips it and
    /// `UniformImage` never tries to write bytes for it.
    @Test func textIsNotUniformable() {
        #expect(ParamValue.text("x").socketType == nil)
        #expect(ParamValue.text("x").isUniformable == false)
    }

    @Test func textSurvivesAnEmptyStringAndNewlines() throws {
        for s in ["", "a\nb", "  spaced  "] {
            let v = ParamValue.text(s)
            #expect(try JSONDecoder().decode(ParamValue.self, from: try JSONEncoder().encode(v)) == v)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter TextParamValueTests`
Expected: FAIL to compile — `ParamValue` has no `text` case.

- [ ] **Step 3: Add the case**

In `ParamValue.swift`, add to the enum and to `socketType`:

```swift
    case enumCase(String)
    case asset(AssetID?)
    /// A formula or a body of MSL (spec §24.2). Never a uniform — `socketType` is `nil`.
    case text(String)
```

```swift
        case .enumCase, .asset, .text: nil
```

`ParamValue` is `Codable` by synthesis, so the round trip follows. Check whether `components(_:)` in `ParamValues` (Core) or `UniformImage` (Render) switches exhaustively over `ParamValue`; if either does, add `.text` returning an empty component list, beside `.enumCase` and `.asset`.

- [ ] **Step 4: Add the param kind**

In `NodeDef.swift`:

```swift
public enum ParamKind: Sendable, Hashable {
    case value(SocketType, range: ClosedRange<Float>?)
    case enumeration([String])
    case asset
    /// Free text, rendered as a field. `multiline` picks a one-line field or an editor.
    case text(multiline: Bool)
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter TextParamValueTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS. Adding an enum case makes non-exhaustive switches fail to compile — fix each by handling `.text` the way `.enumCase`/`.asset` are handled (no uniform, no components), never by adding a `default:` that would silently swallow a future case.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): a text parameter value and kind

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 2: The MSL token scanner

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MSLScanner.identifiers(in: String) -> [String]` — free identifiers in first-appearance order, with MSL keywords, type names, builtin functions, numeric literals and member names after `.` excluded.
  - `MSLScanner.scopeBreakers(in: String) -> [MSLScanner.Violation]` where `Violation` is `{ kind: Kind, line: Int }` and `Kind` is `.preprocessor(String)`, `.unbalancedBrace`, `.bareReturn`.
  - `MSLScanner.loopSites(in: String) -> [Int]` — the 0-based line index of each `for`, `while` or `do` that opens a loop.
  - `MSLScanner.reservedNames: Set<String>`.

This is the one piece every other custom-code task consults, and it is pure text in / values out — so it carries the heaviest test load in the milestone and needs no GPU, no document and no registry.

**It is a scanner, not a parser.** It tokenises: identifiers, numbers, strings, comments, punctuation. It never builds a syntax tree. Where a question needs real grammar (does this loop terminate?) the answer is "we don't ask" — §24.4 caps loops in codegen instead.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct MSLScannerIdentifierTests {
    @Test func findsFreeIdentifiersInFirstAppearanceOrder() {
        #expect(MSLScanner.identifiers(in: "sin(a * 6.28) * b") == ["a", "b"])
        #expect(MSLScanner.identifiers(in: "b + a") == ["b", "a"])
        #expect(MSLScanner.identifiers(in: "a + a + b") == ["a", "b"])
    }

    /// Builtin functions and type names are not sockets. Getting this wrong would give every
    /// expression a socket called `sin`.
    @Test func excludesKeywordsTypesAndBuiltins() {
        #expect(MSLScanner.identifiers(in: "length(float3(a, 0.0, 1.0))") == ["a"])
        #expect(MSLScanner.identifiers(in: "mix(a, b, saturate(t))") == ["a", "b", "t"])
        #expect(MSLScanner.identifiers(in: "float x = 1.0; return x;") == [])
        #expect(MSLScanner.identifiers(in: "clamp(dot(n, l), 0.0, 1.0)") == ["n", "l"])
    }

    /// A swizzle or member is not a socket: `uv.xy` names `uv`, not `xy`.
    @Test func excludesMembersAfterADot() {
        #expect(MSLScanner.identifiers(in: "uv.xy + p.z") == ["uv", "p"])
        #expect(MSLScanner.identifiers(in: "a.rgb * b.a") == ["a", "b"])
    }

    @Test func ignoresCommentsAndNumbers() {
        #expect(MSLScanner.identifiers(in: "a + 1.0e-3 // b\n+ c /* d */") == ["a", "c"])
    }

    /// A local declared inside the body is not an input — it is bound before use.
    @Test func excludesLocalsDeclaredInTheText() {
        #expect(MSLScanner.identifiers(in: "float d = length(uv); d * 2.0") == ["uv"])
    }
}

@Suite struct MSLScannerGuardTests {
    private func kinds(_ s: String) -> [MSLScanner.Violation.Kind] {
        MSLScanner.scopeBreakers(in: s).map(\.kind)
    }

    @Test func refusesPreprocessorDirectives() {
        #expect(kinds("#include <metal_stdlib>\na") == [.preprocessor("include")])
        #expect(kinds("#define X 1\na") == [.preprocessor("define")])
        #expect(kinds("#pragma once\na") == [.preprocessor("pragma")])
    }

    @Test func refusesUnbalancedBraces() {
        #expect(kinds("if (a) { b = 1;") == [.unbalancedBrace])
        #expect(kinds("} float a;") == [.unbalancedBrace])
        #expect(kinds("if (a) { b = 1; }") == [])
    }

    /// A bare `return` would exit the enclosing generated function early, stranding every
    /// statement after the node and leaving the compiler to complain about a neighbour.
    @Test func refusesABareReturn() {
        #expect(kinds("return a;") == [.bareReturn])
        #expect(kinds("out = a;") == [])
    }

    @Test func aBraceInsideAStringOrCommentDoesNotCount() {
        #expect(kinds("// {\nout = a;") == [])
        #expect(kinds("/* } */ out = a;") == [])
    }

    @Test func violationsCarryTheLine() {
        let v = MSLScanner.scopeBreakers(in: "out = a;\n#include <x>\n")
        #expect(v.count == 1)
        #expect(v[0].line == 1)
    }
}

@Suite struct MSLScannerLoopTests {
    @Test func findsEveryLoopOpener() {
        #expect(MSLScanner.loopSites(in: "for (int i = 0; i < n; i++) { s += i; }") == [0])
        #expect(MSLScanner.loopSites(in: "while (t > 0.0) { t -= 1.0; }") == [0])
        #expect(MSLScanner.loopSites(in: "do { t -= 1.0; } while (t > 0.0);") == [0])
    }

    @Test func findsNestedAndMultipleLoops() {
        let s = "for (int i = 0; i < 4; i++) {\n  for (int j = 0; j < 4; j++) {\n    s += 1.0;\n  }\n}"
        #expect(MSLScanner.loopSites(in: s) == [0, 1])
    }

    @Test func doesNotMistakeAnIdentifierForAKeyword() {
        #expect(MSLScanner.loopSites(in: "float former = 1.0; float doer = 2.0;") == [])
        #expect(MSLScanner.loopSites(in: "// for\nout = a;") == [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MSLScanner`
Expected: FAIL to compile — no `MSLScanner`.

- [ ] **Step 3: Write the scanner**

Create `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift`. Structure it as one tokeniser that every public entry point consumes, so comments and strings are skipped once rather than three times:

```swift
import Foundation

/// A token scan over user-written MSL (spec §24.4). Deliberately *not* a parser: it answers
/// questions that tokens can answer — which identifiers are free, whether the text breaks out of
/// its scope, where the loops are — and nothing else. Where a question needs real grammar
/// ("does this loop terminate?") the answer is that we do not ask; §24.4 caps loops in codegen.
public enum MSLScanner {
    public struct Violation: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case preprocessor(String)
            case unbalancedBrace
            case bareReturn
        }
        public let kind: Kind
        /// 0-based line within the user's own text.
        public let line: Int
    }

    struct Token: Equatable {
        enum Kind: Equatable { case identifier, number, punctuation }
        let kind: Kind
        let text: String
        let line: Int
        /// True when the previous non-space token was `.`, so this is a member or swizzle.
        let afterDot: Bool
    }

    /// MSL keywords, type names, qualifiers and the stdlib functions a formula may call.
    /// An identifier in this set is never a socket.
    public static let reservedNames: Set<String> = [
        // keywords and qualifiers
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case",
        "default", "const", "constexpr", "static", "struct", "using", "namespace", "true", "false",
        "thread", "device", "constant", "threadgroup", "inline", "auto", "void",
        // scalar and vector types
        "bool", "char", "short", "int", "uint", "long", "half", "float", "double",
        "bool2", "bool3", "bool4", "int2", "int3", "int4", "uint2", "uint3", "uint4",
        "half2", "half3", "half4", "float2", "float3", "float4",
        "float2x2", "float3x3", "float4x4", "half2x2", "half3x3", "half4x4",
        "texture2d", "sampler",
        // the stdlib subset a shader author reaches for
        "abs", "acos", "asin", "atan", "atan2", "ceil", "clamp", "cos", "cosh", "cross",
        "degrees", "distance", "dot", "exp", "exp2", "faceforward", "floor", "fma", "fract",
        "length", "log", "log2", "max", "min", "mix", "mod", "modf", "normalize", "pow",
        "radians", "reflect", "refract", "round", "rsqrt", "saturate", "sign", "sin", "sinh",
        "smoothstep", "sqrt", "step", "tan", "tanh", "trunc", "isnan", "isinf", "select",
    ]

    /// Free identifiers in first-appearance order: not reserved, not a member after `.`, and not
    /// bound by a declaration earlier in the same text.
    public static func identifiers(in source: String) -> [String] {
        let tokens = tokenise(source)
        let declared = declaredLocals(tokens)
        var seen = Set<String>(), out: [String] = []
        for t in tokens where t.kind == .identifier && !t.afterDot {
            guard !reservedNames.contains(t.text), !declared.contains(t.text) else { continue }
            if seen.insert(t.text).inserted { out.append(t.text) }
        }
        return out
    }

    /// A name bound by `<type> <name>` earlier in the text is a local, not an input.
    private static func declaredLocals(_ tokens: [Token]) -> Set<String> {
        var out = Set<String>()
        for (i, t) in tokens.enumerated() where t.kind == .identifier && reservedNames.contains(t.text) {
            guard isTypeName(t.text), i + 1 < tokens.count else { continue }
            let next = tokens[i + 1]
            if next.kind == .identifier, !next.afterDot, !reservedNames.contains(next.text) {
                out.insert(next.text)
            }
        }
        return out
    }

    private static func isTypeName(_ s: String) -> Bool {
        s == "void" || s.hasPrefix("float") || s.hasPrefix("half") || s.hasPrefix("int")
            || s.hasPrefix("uint") || s.hasPrefix("bool") || s == "auto" || s == "short"
            || s == "long" || s == "char" || s == "double"
    }

    public static func scopeBreakers(in source: String) -> [Violation] {
        var out: [Violation] = []
        for (i, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let name = line.dropFirst().prefix { $0.isLetter }
            out.append(Violation(kind: .preprocessor(String(name)), line: i))
        }
        let tokens = tokenise(source)
        var depth = 0, unbalancedAt: Int?
        for t in tokens where t.kind == .punctuation {
            if t.text == "{" { depth += 1 }
            if t.text == "}" {
                depth -= 1
                if depth < 0, unbalancedAt == nil { unbalancedAt = t.line }
            }
        }
        if depth != 0 || unbalancedAt != nil {
            out.append(Violation(kind: .unbalancedBrace, line: unbalancedAt ?? (tokens.last?.line ?? 0)))
        }
        for t in tokens where t.kind == .identifier && t.text == "return" && !t.afterDot {
            out.append(Violation(kind: .bareReturn, line: t.line))
        }
        return out.sorted { $0.line < $1.line }
    }

    /// The 0-based line of every `for`, `while` or `do` that opens a loop. A `while` that closes a
    /// `do` is not a separate site — hardening the `do` covers it.
    public static func loopSites(in source: String) -> [Int] {
        var out: [Int] = []
        var pendingDo = false
        for t in tokenise(source) where t.kind == .identifier && !t.afterDot {
            switch t.text {
            case "for": out.append(t.line)
            case "do": out.append(t.line); pendingDo = true
            case "while":
                if pendingDo { pendingDo = false } else { out.append(t.line) }
            default: break
            }
        }
        return out.sorted()
    }

    /// One pass: identifiers, numbers and punctuation, with `//` and `/* */` comments and string
    /// literals skipped so a brace inside either never counts.
    static func tokenise(_ source: String) -> [Token] {
        var out: [Token] = []
        var line = 0, afterDot = false
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == "/" , i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i = min(i + 2, chars.count)
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c.isWhitespace { i += 1; continue }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    s.append(chars[i]); i += 1
                }
                out.append(Token(kind: .identifier, text: s, line: line, afterDot: afterDot))
                afterDot = false
                continue
            }
            if c.isNumber {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e"
                    || chars[i] == "E" || chars[i] == "f" || chars[i] == "-" && (s.last == "e" || s.last == "E") {
                    s.append(chars[i]); i += 1
                }
                out.append(Token(kind: .number, text: s, line: line, afterDot: false))
                afterDot = false
                continue
            }
            out.append(Token(kind: .punctuation, text: String(c), line: line, afterDot: false))
            afterDot = (c == ".")
            i += 1
        }
        return out
    }
}
```

The number scan must consume a `.` inside `1.0` without setting `afterDot` — that is why numbers are lexed before punctuation, and it is what makes `a + 1.0e-3 // b` yield `["a"]` rather than `["a", "e"]`.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MSLScanner`
Expected: PASS, all three suites.

If `excludesLocalsDeclaredInTheText` fails, the declaration heuristic is the likely cause — `float d = length(uv)` must bind `d`. If `ignoresCommentsAndNumbers` fails, check the number lexer's handling of `1.0e-3`.

- [ ] **Step 5: Run the whole suite and commit**

Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift \
        MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift
git commit -m "feat(core): a token scanner for user-written MSL

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 3: The Expression node

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/ExpressionNode.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/NodeShape.swift:52-70` (the `.builtin` case)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/BuiltinNodes.swift` (`all`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ExpressionNodeTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/BuiltinLibraryTests.swift` (extend the id census)

**Interfaces:**
- Consumes: `ParamValue.text`, `ParamKind.text` (Task 1); `MSLScanner.identifiers(in:)` (Task 2).
- Produces: node id `utility.expression`; `ExpressionNode.formulaParam = "formula"`, `ExpressionNode.outputTypeParam = "type"`; `ExpressionNode.sockets(forFormula:) -> [SocketDecl]`; `ExpressionNode.shape(for:) -> NodeShape`.

The formula lives on the instance, so the node's **shape depends on its params** — the first builtin for which that is true. `shape(of:in:registry:)` currently maps a builtin straight from the registry; it gains one special case.

**Types (spec §24.2).** Each inferred input gets its *own* generic — `T0`, `T1`, … in socket order, each over `anyFloat` — never a shared `T`. Wiring a `float2` into `a` and a `float` into `b` is ordinary in an expression, and one shared parameter would force them to unify and reject it. The output type is a separate `.enumeration` param, because a result type cannot be read off the inputs.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/ExpressionNodeTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct ExpressionNodeTests {
    private func instance(_ formula: String, type: String = "float") -> NodeInstance {
        NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                     params: ["formula": .text(formula), "type": .enumCase(type)])
    }

    private func shape(_ formula: String, type: String = "float") -> NodeShape {
        var doc = ShaderDocument()
        let n = instance(formula, type: type)
        doc.root.nodes[n.id] = n
        return doc.shape(of: n, in: .root, registry: .builtin)!
    }

    @Test func theNodeIsRegistered() {
        let d = NodeRegistry.builtin["utility.expression"]
        #expect(d != nil)
        #expect(d?.category == .utility)
        #expect(d?.param(named: "formula") != nil)
        #expect(d?.param(named: "type") != nil)
    }

    @Test func socketsComeFromTheFormula() {
        #expect(shape("sin(a * 6.28) * b").inputs.map(\.name) == ["a", "b"])
        #expect(shape("b + a").inputs.map(\.name) == ["b", "a"])
        #expect(shape("1.0").inputs.isEmpty)
    }

    /// Every inferred input gets its own generic, so a float2 and a float can be wired into the
    /// same expression (spec §24.2). One shared T would reject that.
    @Test func eachInputGetsItsOwnGeneric() {
        let s = shape("a + b")
        #expect(s.inputs.map(\.type) == [.generic("T0"), .generic("T1")])
        #expect(s.generics["T0"] != nil)
        #expect(s.generics["T1"] != nil)
        #expect(s.generics.count == 2)
    }

    @Test func theOutputTypeComesFromTheTypeParam() {
        #expect(shape("a", type: "float").outputs.first?.type == .concrete(.float))
        #expect(shape("a", type: "float3").outputs.first?.type == .concrete(.float3))
        #expect(shape("a", type: "color").outputs.first?.type == .concrete(.color))
        #expect(shape("a").outputs.map(\.name) == ["out"])
    }

    /// The shape must not change when the formula does not, or the canvas would rewire on every
    /// keystroke; and it must change when it does, or a new socket never appears.
    @Test func theShapeTracksTheFormula() {
        #expect(shape("a").inputs.map(\.name) == ["a"])
        #expect(shape("a + b").inputs.map(\.name) == ["a", "b"])
        #expect(shape("a").inputs.map(\.name) == ["a"])
    }

    @Test func anEmptyOrMissingFormulaYieldsNoInputs() {
        #expect(shape("").inputs.isEmpty)
        var doc = ShaderDocument()
        let bare = NodeInstance(kind: .builtin("utility.expression"), position: .zero)
        doc.root.nodes[bare.id] = bare
        #expect(doc.shape(of: bare, in: .root, registry: .builtin)?.inputs.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ExpressionNodeTests`
Expected: FAIL — no `utility.expression` in the registry.

- [ ] **Step 3: Write the node**

Create `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/ExpressionNode.swift`:

```swift
import Foundation

/// The Expression node (spec §24.2): a one-line formula whose sockets are the identifiers it
/// names. Unlike a Custom MSL definition it is *not* reusable — the formula is instance data, so
/// two Expression nodes are independent, which is what you want for a one-liner.
public enum ExpressionNode {
    public static let id = "utility.expression"
    public static let formulaParam = "formula"
    public static let outputTypeParam = "type"

    /// The output types offered, in picker order.
    public static let outputTypes: [String] = ["float", "float2", "float3", "float4", "color", "int", "bool"]

    static func socketType(named n: String) -> SocketType {
        SocketType(rawValue: n) ?? .float
    }

    /// The registry entry. Its declared sockets are empty: the real ones are computed per instance
    /// by `shape(for:)`, because they depend on a parameter.
    static let def = NodeDef(
        id: id, title: "Expression", category: .utility,
        params: [
            ParamDecl(name: formulaParam, label: "Formula", kind: .text(multiline: false),
                      defaultValue: .text("")),
            ParamDecl(name: outputTypeParam, label: "Type", kind: .enumeration(outputTypes),
                      defaultValue: .enumCase("float")),
        ],
        // Never emitted: `Emitter` substitutes the instance's formula (Task 4).
        body: .template(""))

    /// One input per free identifier, in first-appearance order, each with its own generic.
    public static func sockets(forFormula formula: String) -> [SocketDecl] {
        MSLScanner.identifiers(in: formula).enumerated().map { i, name in
            SocketDecl(name: name, label: name, type: .generic("T\(i)"), default: .value(.float(0)))
        }
    }

    public static func generics(forFormula formula: String) -> [String: [SocketType]] {
        var out: [String: [SocketType]] = [:]
        for i in MSLScanner.identifiers(in: formula).indices { out["T\(i)"] = BuiltinNodes.anyFloat }
        return out
    }

    /// The shape of one instance: sockets from its formula, output from its type param.
    public static func shape(for node: NodeInstance) -> NodeShape {
        let formula: String = { if case .text(let s)? = node.params[formulaParam] { return s } else { return "" } }()
        let typeName: String = { if case .enumCase(let s)? = node.params[outputTypeParam] { return s } else { return "float" } }()
        return NodeShape(title: node.customTitle ?? def.title, category: def.category,
                         inputs: sockets(forFormula: formula),
                         outputs: [SocketDecl(name: "out", label: "Out", type: .concrete(socketType(named: typeName)))],
                         params: def.params,
                         generics: generics(forFormula: formula),
                         style: def.style)
    }
}

extension BuiltinNodes {
    static let expression: [NodeDef] = [ExpressionNode.def]
}
```

Check `SocketType`'s raw values before writing `socketType(named:)` — it is `String`-backed with cases `float, float2, float3, float4, color, int, bool, texture`, so `SocketType(rawValue:)` works directly. Check `TypeRef`'s spelling for a generic (`.generic(String)`) and adapt if it differs.

- [ ] **Step 4: Compute the shape per instance**

In `NodeShape.swift`, the `.builtin` case becomes:

```swift
        case .builtin(let id):
            // The Expression node's sockets come from its formula, so its shape depends on the
            // instance rather than the registry (spec §24.2). Every other builtin is its def.
            if id == ExpressionNode.id { return ExpressionNode.shape(for: node) }
            return registry[id].map(NodeShape.init(def:))
```

Register it in `BuiltinNodes.all`:

```swift
    public static let all: [NodeDef] = input + math + vector + sdf + noise + color + utility + texture + output + material3D + expression
```

- [ ] **Step 5: Extend the id census**

In `BuiltinLibraryTests.swift`, add `"utility.expression"` to the `expected` set in `registryContainsTheV1Set`.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter ExpressionNodeTests`
Run: `swift test --package-path MetalNodesKit --filter BuiltinLibraryTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS. `everyRequiredStdlibFunctionExists` and the placeholder-vocabulary tests must still pass — the Expression def's body is empty, so it names no `{sys.…}`.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): the Expression node, sockets derived from its formula

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 4: Emitting an Expression

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift` (the `.builtin` branch of pass 2)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ExpressionNodeTests.swift` (append)

**Interfaces:**
- Consumes: `ExpressionNode.formulaParam`, `MSLScanner.identifiers(in:)`.
- Produces: an Expression node emits exactly one statement, `<outVar> = <formula with identifiers substituted>;`, and no function.

An Expression **inlines**. The emitter already substitutes `{in.x}` and `{out.x}` in a builtin's template; the only difference is that this template is built from the instance's formula rather than read from the registry. Building it as a template and handing it to the existing `substitute` keeps one substitution path rather than two.

- [ ] **Step 1: Write the failing test**

Append to `ExpressionNodeTests.swift`:

```swift
@Suite struct ExpressionEmissionTests {
    /// A document with one Expression wired into the fragment terminal.
    private func document(_ formula: String, type: String = "color") -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text(formula), "type": .enumCase(type)])
        g.nodes[terminal.id] = terminal
        g.nodes[expr.id] = expr
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        return doc
    }

    @Test func theFormulaBecomesOneStatement() throws {
        let s = try ShaderGenerator.generate(document("float4(uvx, 0.0, 0.0, 1.0)")).source
        // The identifier is substituted for whatever the caller wired or defaulted; the literal
        // text around it survives verbatim.
        #expect(s.contains("float4("))
        #expect(s.contains(", 0.0, 0.0, 1.0)"))
        #expect(!s.contains("uvx"))   // substituted, not passed through
    }

    @Test func anExpressionEmitsNoFunction() throws {
        let s = try ShaderGenerator.generate(document("a * 2.0")).source
        #expect(!s.contains("mn_g_"))
    }

    /// Two Expression nodes are independent — the point of instance data (spec §24.2).
    @Test func twoExpressionsEmitTwoStatements() throws {
        var doc = document("a * 2.0")
        let second = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                  params: ["formula": .text("a * 3.0"), "type": .enumCase("float")])
        doc.root.nodes[second.id] = second
        let mix = NodeInstance(kind: .builtin("math.mix"), position: .zero)
        doc.root.nodes[mix.id] = mix
        doc.root.inputs[SocketRef(mix.id, "a")] = SocketRef(second.id, "out")
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!
        doc.root.inputs[SocketRef(terminal.id, "color")] = SocketRef(mix.id, "out")
        let s = try ShaderGenerator.generate(doc).source
        #expect(s.contains("* 2.0"))
        #expect(s.contains("* 3.0"))
    }

    @Test func generationIsDeterministic() throws {
        let doc = document("a + b")
        #expect(try ShaderGenerator.generate(doc).source == (try ShaderGenerator.generate(doc).source))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ExpressionEmissionTests`
Expected: FAIL — the empty template emits nothing, so the terminal reads an unassigned variable.

- [ ] **Step 3: Emit the formula**

In `Emitter.emit`'s pass 2, inside `case .builtin(let defID)`, the body is chosen by `switch def.body`. Add the Expression case *before* that switch, since its template is per-instance:

```swift
                let lines: [String]
                if defID == ExpressionNode.id {
                    // The template is the instance's formula with each identifier rewritten to the
                    // placeholder the substituter already understands, so one substitution path
                    // serves both library bodies and user formulas (spec §24.2).
                    lines = substitute(ExpressionNode.template(for: inst), ctx)
                } else {
                    switch def.body {
                    case .template(let t): lines = substitute(t, ctx)
                    case .variants(let param, let table):
                        let defaultCase: String? = { if case .enumCase(let c) = def.param(named: param)!.defaultValue { return c } else { return nil } }()
                        let chosen = enums[param].flatMap { table[$0] != nil ? $0 : nil } ?? defaultCase
                        lines = substitute(chosen.flatMap { table[$0] } ?? "", ctx)
                    case .custom(let f): lines = f(ctx)
                    }
                }
```

Add to `ExpressionNode`:

```swift
    /// The instance's formula as an emitter template: `a * 2.0` becomes `{out.out} = {in.a} * 2.0;`.
    /// Identifiers are replaced by whole-token match, so `a` inside `saturate` is untouched.
    static func template(for node: NodeInstance) -> String {
        let formula: String = { if case .text(let s)? = node.params[formulaParam] { return s } else { return "" } }()
        guard !formula.isEmpty else { return "{out.out} = 0.0;" }
        var out = formula
        for name in MSLScanner.identifiers(in: formula) {
            out = out.replacing(try! Regex("\\b\(NSRegularExpression.escapedPattern(for: name))\\b"),
                                with: "{in.\(name)}")
        }
        return "{out.out} = \(out);"
    }
```

A whole-token replacement is required: a plain string replace of `a` would corrupt `saturate` and `float4`. Prefer reusing `MSLScanner.tokenise` to rebuild the string token by token if the regex proves fragile — that is the more robust route and the scanner already produces the positions.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter ExpressionEmissionTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS with no golden movement — no existing document contains an Expression node.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): emit an Expression node as one inlined statement

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 5: A definition body that is graph *or* text

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift` (`GroupDefinition`)
- Modify: every site reading `definition.graph` — 29 references across `Sources` at the time of writing
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/CustomMSLDefinitionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DefinitionBody.graph(Graph)` / `.msl(String)`; `GroupDefinition.body: DefinitionBody`; `GroupDefinition.graph: Graph` survives as a **read-only computed convenience** returning an empty `Graph` for a `.msl` body, so call sites that only read keep compiling.

This is the riskiest task in the milestone: it changes a type every group feature reads. It carries almost no new behaviour on purpose — a representation change, landed and reviewed on its own, so that Task 6's emission lands against a stable shape.

**The one behavioural change it does carry** is `GroupOperations.ungroup`: splicing a definition's subgraph into its parent is meaningless for a body that has no subgraph, so it returns `nil` for a `.msl` definition rather than deleting the instance and the code with it. Every other operation in `GroupOperations.swift` — `rename`, `makeUnique`, `deleteDefinition`, `addSocket`, `renameSocket`, `removeSocket`, `setAccent` — is body-agnostic once `body` is a stored property, and the tests above are the proof rather than the assumption.

**Migration is the acceptance criterion.** Every M0–M7 document writes a `graph` key. `init(from:)` decodes `body` when present and otherwise wraps the legacy `graph` — the same shape as §23.2's `decodeIfPresent` defaults.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/CustomMSLDefinitionTests.swift`:

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct DefinitionBodyTests {
    @Test func aGraphBodyRoundTrips() throws {
        var d = GroupDefinition(name: "G")
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        var g = Graph(); g.nodes[n.id] = n
        d.body = .graph(g)
        let back = try JSONDecoder().decode(GroupDefinition.self, from: try JSONEncoder().encode(d))
        #expect(back == d)
        if case .graph(let bg) = back.body { #expect(bg.nodes.count == 1) } else { Issue.record("not a graph body") }
    }

    @Test func anMSLBodyRoundTrips() throws {
        var d = GroupDefinition(name: "Wobble")
        d.body = .msl("out = in_a * 2.0;")
        let back = try JSONDecoder().decode(GroupDefinition.self, from: try JSONEncoder().encode(d))
        #expect(back == d)
        if case .msl(let s) = back.body { #expect(s == "out = in_a * 2.0;") } else { Issue.record("not an msl body") }
    }

    /// Every document written before M8 carries a `graph` key and no `body`. Losing these is the
    /// worst defect this milestone could ship.
    @Test func aLegacyDefinitionWithOnlyAGraphKeyStillDecodes() throws {
        let json = Data("""
        {"id":{"raw":"E63408AB-F398-45E3-A306-E8B989C079CC"},"name":"Legacy","inputs":[],"outputs":[],
         "graph":{"nodes":{},"inputs":{}},"accent":"purple"}
        """.utf8)
        let d = try JSONDecoder().decode(GroupDefinition.self, from: json)
        #expect(d.name == "Legacy")
        if case .graph = d.body {} else { Issue.record("legacy graph did not become a .graph body") }
    }

    /// A real M7 document, loaded end to end.
    @Test func anExistingSampleDocumentStillLoads() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let back = try JSONDecoder().decode(ShaderDocument.self, from: try JSONEncoder().encode(doc))
        #expect(back.definitions.count == doc.definitions.count)
        #expect(GraphValidator.validate(document: back, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }.isEmpty)
    }

    @Test func theGraphConvenienceReadsEmptyForAnMSLBody() {
        var d = GroupDefinition(name: "W")
        d.body = .msl("out = 1.0;")
        #expect(d.graph.nodes.isEmpty)
    }
}

/// §24.9: every definition operation must behave over a `.msl` body, not only a `.graph` one.
@Suite struct MSLDefinitionOperationsTests {
    private func document() -> (ShaderDocument, GroupID, NodeID) {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Tint")
        def.inputs = [SocketDecl(name: "a", label: "A", type: .concrete(.float), default: .value(.float(0)))]
        def.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float))]
        def.body = .msl("out = a * 2.0;")
        doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), position: .zero)
        doc.root.nodes[inst.id] = inst
        return (doc, def.id, inst.id)
    }

    @Test func renamingKeepsTheBody() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.rename(id, to: "Warm", in: doc))
        #expect(out.definitions[id]?.name == "Warm")
        guard case .msl(let b) = try #require(out.definitions[id]).body else {
            Issue.record("body stopped being msl"); return
        }
        #expect(b == "out = a * 2.0;")
    }

    @Test func makeUniqueCopiesTheText() throws {
        let (doc, id, inst) = document()
        let out = try #require(GroupOperations.makeUnique(inst, in: .root, of: doc))
        #expect(out.definition != id)
        guard case .msl(let b) = try #require(out.document.definitions[out.definition]).body else {
            Issue.record("copy is not an msl body"); return
        }
        #expect(b == "out = a * 2.0;")
        // The original is untouched — that is what "unique" means.
        guard case .msl(let orig) = try #require(out.document.definitions[id]).body else {
            Issue.record("original changed shape"); return
        }
        #expect(orig == "out = a * 2.0;")
    }

    @Test func deletingRemovesDefinitionAndInstances() throws {
        let (doc, id, inst) = document()
        let out = try #require(GroupOperations.deleteDefinition(id, in: doc))
        #expect(out.definitions[id] == nil)
        #expect(out.root.nodes[inst] == nil)
    }

    /// Ungrouping splices a definition's subgraph into its parent. A `.msl` body has no subgraph
    /// to splice, so the operation has no meaning and must refuse rather than silently delete the
    /// instance and its code.
    @Test func ungroupingACodeDefinitionIsRefused() {
        let (doc, _, inst) = document()
        #expect(GroupOperations.ungroup(inst, in: .root, of: doc) == nil)
    }

    /// Renaming a socket renames the function's parameter. The user's text is never rewritten
    /// (Global Constraints), so the body now reads an identifier that no longer exists — and the
    /// compiler says so, on the user's own line (Task 9). That is the intended behaviour, not a
    /// gap: silently editing someone's code is worse than a legible error.
    @Test func renamingASocketLeavesTheBodyAlone() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.renameSocket(id, kind: .input, from: "a", to: "amount", in: doc))
        #expect(out.definitions[id]?.inputs.map(\.name) == ["amount"])
        guard case .msl(let b) = try #require(out.definitions[id]).body else {
            Issue.record("body stopped being msl"); return
        }
        #expect(b == "out = a * 2.0;")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter DefinitionBodyTests`
Expected: FAIL to compile — `GroupDefinition` has no `body`.

- [ ] **Step 3: Add the sum type**

In `ShaderDocument.swift`:

```swift
/// What a definition's function is built from (spec §24.3): a subgraph, as every definition was
/// before M8, or hand-written MSL. Both emit one function called once per instance.
public enum DefinitionBody: Codable, Sendable, Hashable {
    case graph(Graph)
    case msl(String)
}
```

`GroupDefinition` gains `public var body: DefinitionBody` in place of `public var graph: Graph`, plus the convenience:

```swift
    /// The subgraph, or an empty one for a `.msl` body. Read-only: writing a graph into a text
    /// definition is a category error, so mutating call sites must switch on `body` instead.
    public var graph: Graph {
        if case .graph(let g) = body { return g } else { return Graph() }
    }
```

`init(id:name:inputs:outputs:graph:accent:)` keeps its signature and wraps: `self.body = .graph(graph)`. That keeps every construction site compiling unchanged.

- [ ] **Step 4: Migrate the decode**

Give `GroupDefinition` an explicit `Codable` conformance:

```swift
extension GroupDefinition {
    private enum Keys: String, CodingKey { case id, name, inputs, outputs, body, graph, accent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(GroupID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        inputs = try c.decodeIfPresent([SocketDecl].self, forKey: .inputs) ?? []
        outputs = try c.decodeIfPresent([SocketDecl].self, forKey: .outputs) ?? []
        accent = try c.decodeIfPresent(DraculaAccent.self, forKey: .accent) ?? .purple
        // M8 writes `body`; every document before it wrote `graph` (spec §24.3).
        if let b = try c.decodeIfPresent(DefinitionBody.self, forKey: .body) {
            body = b
        } else {
            body = .graph(try c.decodeIfPresent(Graph.self, forKey: .graph) ?? Graph())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(body, forKey: .body)
        try c.encode(accent, forKey: .accent)
    }
}
```

- [ ] **Step 5: Fix the mutating call sites**

`git grep -n "\.graph" MetalNodesKit/Sources | grep -v "doc.root"` finds them. Every site that only *reads* keeps compiling through the convenience. Every site that **writes** (`def.graph = …`, `def.graph.nodes[x] = …`) must switch on `body` and rebuild:

```swift
        guard case .graph(var g) = def.body else { return nil }   // or `continue`, per the caller
        g.nodes[id] = node
        def.body = .graph(g)
```

Where a function's whole purpose is subgraph surgery — group operations, dependency walking, definition validation — returning early for a `.msl` body is correct: a text definition has no subgraph to operate on, and Task 6 gives it its own emission path.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter DefinitionBodyTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS with **no golden movement and no group test failing**. The entire existing group suite is this task's regression gate: if `GroupOperationsTests`, `GroupCodegenTests`, `GroupValidationTests` or `GroupViewerTests` moves, the representation change was not neutral and the fix belongs in the source, not the test.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "refactor(core): a definition body is a graph or MSL text

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 6: Emitting a Custom MSL definition

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Groups/GroupCodegen.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/CustomMSLDefinitionTests.swift` (append)

**Interfaces:**
- Consumes: `DefinitionBody` (Task 5).
- Produces: a `.msl` definition emits one `GroupFunction` whose `source` is the user's statements inside the standard signature, callable exactly like a graph-backed one.

`GroupCodegen.function(for:document:registry:functions:)` already builds the signature from `inputs`/`outputs` and packs the result struct. For a `.msl` body only the *middle* changes: instead of emitting a subgraph's statements, it emits the user's, with the declared sockets in scope.

**Naming inside the body.** Inputs arrive as `in_<name>`, exactly as the graph path spells them (§20.4), and the user assigns the outputs by their declared names. The epilogue packing outputs into the result struct is unchanged, so a `.msl` definition is indistinguishable to its caller.

- [ ] **Step 1: Write the failing test**

Append to `CustomMSLDefinitionTests.swift`:

```swift
@Suite struct CustomMSLEmissionTests {
    /// A document with one `.msl` definition instantiated twice, both feeding the terminal.
    private func document(_ body: String = "out = in_a * 2.0;") -> ShaderDocument {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Wobble")
        def.inputs = [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl(body)
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let one = NodeInstance(kind: .group(def.id), position: .zero)
        let two = NodeInstance(kind: .group(def.id), position: .zero)
        let mix = NodeInstance(kind: .builtin("math.mix"), position: .zero)
        for n in [terminal, one, two, mix] { g.nodes[n.id] = n }
        g.inputs[SocketRef(mix.id, "a")] = SocketRef(one.id, "out")
        g.inputs[SocketRef(mix.id, "b")] = SocketRef(two.id, "out")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(mix.id, "out")
        doc.root = g
        return doc
    }

    @Test func theUserStatementsLandInTheFunctionBody() throws {
        let s = try ShaderGenerator.generate(document()).source
        #expect(s.contains("in_a * 2.0"))
        #expect(s.contains("mn_g_Wobble_"))
    }

    /// The property that distinguishes a definition from an Expression node: one function, two
    /// call sites (spec §24.3).
    @Test func twoInstancesShareOneFunction() throws {
        let s = try ShaderGenerator.generate(document()).source
        let decls = s.components(separatedBy: "mn_g_Wobble_").count - 1
        // One declaration plus two call sites = three occurrences of the function name.
        #expect(decls == 3)
    }

    @Test func aMultiLineBodyIsEmittedInOrder() throws {
        let s = try ShaderGenerator.generate(document("float d = in_a * 3.0;\nout = d + 1.0;")).source
        let d = try #require(s.range(of: "float d = in_a * 3.0;"))
        let o = try #require(s.range(of: "out = d + 1.0;"))
        #expect(d.lowerBound < o.lowerBound)
    }

    @Test func generationIsDeterministic() throws {
        let doc = document()
        #expect(try ShaderGenerator.generate(doc).source == (try ShaderGenerator.generate(doc).source))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter CustomMSLEmissionTests`
Expected: FAIL — `GroupCodegen` reads `def.graph`, which is empty for a `.msl` body, so the function emits no statements and the outputs are never assigned.

- [ ] **Step 3: Emit the text body**

In `GroupCodegen.function(for:…)`, branch on the body immediately after the signature is written. Read the existing function first: it computes an `Emitter.Output` from the definition's graph, then writes the result struct, signature, statements and epilogue. For `.msl`, the statements come from the text and there is no `Emitter.Output` — so the uniform and texture parameter lists are empty, and `requiredStdlib` is empty too:

```swift
        switch def.body {
        case .graph(let graph):
            // Every existing line of this function moves into this branch verbatim — the
            // `Emitter` run over `graph`, its statements, its uniform and texture parameter
            // lists, its `requiredStdlib`. Nothing about the graph path changes; it is only
            // indented one level. Bind `graph` here rather than reading `def.graph`, so the
            // convenience accessor has no live caller left inside codegen.
        case .msl(let text):
            // The user's statements, indented into the function. Inputs are already in scope as
            // `in_<name>`; the user assigns the outputs by their declared names, which the
            // epilogue then packs into the result struct (spec §24.3).
            for decl in def.outputs {
                b.add("    \(concrete(decl.type).mslName) \(decl.name) = \(zeroLiteral(concrete(decl.type)));")
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                b.add("    " + line)
            }
        }
```

Declaring each output zero-initialised before the user's text means a body that forgets to assign one still compiles and renders black, rather than failing with an error about generated scaffolding the user cannot see.

A `.msl` definition takes no uniform or texture parameters: it has no nodes, so nothing requests a slot. Its `GroupFunction` is built with `uniformParams: []` and `textureParams: []`, and callers therefore pass only the four leading system values and the declared inputs.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter CustomMSLEmissionTests`
Run: `swift test --package-path MetalNodesKit --filter GroupCodegenTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS, with `GroupCodegenTests`' goldens unmoved — the `.graph` branch is the old code verbatim.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): emit a Custom MSL definition as one shared function

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 7: Wire the scope-breaker guards into validation

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/CustomCodeValidation.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift` (document-level entry point)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/CustomCodeValidationTests.swift`

**Interfaces:**
- Consumes: `MSLScanner.scopeBreakers(in:)` (Task 2); `DefinitionBody` (Task 5); `ExpressionNode.formulaParam` (Task 3).
- Produces: `CustomCodeValidation.diagnostics(document:registry:) -> [Diagnostic]`, called from `GraphValidator.validate(document:registry:target:)` alongside the existing rules.

Task 2 built the scanner; nothing calls it. This task makes a scope breaker a refusal the user sees, for both node kinds.

**Why these three refuse rather than warn (spec §24.4):** each silently reshapes the surrounding generated program, so the Metal compiler's complaint lands on a neighbouring node. Refusing them is what keeps every *other* diagnostic trustworthy.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/CustomCodeValidationTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct CustomCodeValidationTests {
    private func expressionDoc(_ formula: String) -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let e = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                             params: ["formula": .text(formula), "type": .enumCase("color")])
        g.nodes[t.id] = t; g.nodes[e.id] = e
        g.inputs[SocketRef(t.id, "color")] = SocketRef(e.id, "out")
        doc.root = g
        return doc
    }

    private func definitionDoc(_ body: String) -> ShaderDocument {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl(body)
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[t.id] = t; g.nodes[i.id] = i
        doc.root = g
        return doc
    }

    private func errors(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
    }

    @Test func aPreprocessorDirectiveInADefinitionIsRefused() {
        let d = errors(definitionDoc("#include <metal_stdlib>\nout = 1.0;"))
        #expect(d.contains { $0.message.lowercased().contains("include") })
    }

    @Test func anUnbalancedBraceIsRefused() {
        #expect(errors(definitionDoc("if (true) { out = 1.0;")).contains { $0.message.lowercased().contains("brace") })
    }

    @Test func aBareReturnIsRefused() {
        #expect(errors(definitionDoc("return;")).contains { $0.message.lowercased().contains("return") })
    }

    @Test func aWellFormedBodyIsAccepted() {
        #expect(errors(definitionDoc("if (true) { out = 1.0; } else { out = 2.0; }")).isEmpty)
    }

    /// The same guards apply to an Expression's formula, anchored on the node so the canvas can
    /// outline it.
    @Test func anExpressionFormulaIsGuardedAndAnchored() {
        let doc = expressionDoc("return a;")
        let d = errors(doc)
        #expect(d.contains { $0.message.lowercased().contains("return") })
        #expect(d.first { $0.message.lowercased().contains("return") }?.node != nil)
    }

    @Test func anOrdinaryFormulaIsAccepted() {
        #expect(errors(expressionDoc("float4(1.0, 0.0, 0.0, 1.0)")).isEmpty)
    }

    /// A definition nothing instantiates still validates — a broken body the user is mid-edit on
    /// should show its error, not hide until wired.
    @Test func anUninstantiatedDefinitionIsStillChecked() {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Orphan")
        def.body = .msl("#pragma once")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        #expect(errors(doc).contains { $0.message.lowercased().contains("pragma") })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter CustomCodeValidationTests`
Expected: FAIL — nothing calls the scanner.

- [ ] **Step 3: Write the rules**

Create `MetalNodesKit/Sources/MetalNodesCore/Codegen/CustomCodeValidation.swift`:

```swift
import Foundation

/// What user-written code is refused before it ever reaches the Metal compiler (spec §24.4).
/// Only the scope breakers refuse: loops are hardened by codegen (Task 8) and accessor legality
/// is the environment's question (Task 11), so this file stays small on purpose.
public enum CustomCodeValidation {
    public static func diagnostics(document doc: ShaderDocument, registry: NodeRegistry) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // Expression formulas, in the root and in every definition's graph.
        for (node, _) in allNodes(doc) {
            guard case .builtin(ExpressionNode.id) = node.kind,
                  case .text(let formula)? = node.params[ExpressionNode.formulaParam] else { continue }
            out += MSLScanner.scopeBreakers(in: formula).map {
                Diagnostic(.error, message(for: $0), node: node.id, socket: ExpressionNode.formulaParam)
            }
        }

        // Custom MSL bodies. A definition is checked whether or not it is instantiated: the user
        // is editing it now and should see the error now.
        for def in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            guard case .msl(let text) = def.body else { continue }
            out += MSLScanner.scopeBreakers(in: text).map {
                Diagnostic(.error, "\(def.name): \(message(for: $0))")
            }
        }
        return out
    }

    static func message(for v: MSLScanner.Violation) -> String {
        switch v.kind {
        case .preprocessor(let name):
            "`#\(name)` is not allowed in custom code — it would reshape the whole generated program"
        case .unbalancedBrace:
            "Unbalanced brace — the body must open and close every block it starts"
        case .bareReturn:
            "`return` would exit the generated function early — assign the outputs instead"
        }
    }

    private static func allNodes(_ doc: ShaderDocument) -> [(NodeInstance, GraphPath)] {
        var out = doc.root.nodes.values
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
            .map { ($0, GraphPath.root) }
        for d in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            guard case .graph(let g) = d.body else { continue }
            out += g.nodes.values
                .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
                .map { ($0, GraphPath.definition(d.id)) }
        }
        return out
    }
}
```

- [ ] **Step 4: Call it**

In `Validation.swift`'s document-level entry point, append to the return:

```swift
        return out + textureTargetDiagnostics(doc, target: target, reachable: reachable)
                   + MaterialValidation.diagnostics(document: doc, registry: registry, target: target, reachable: reachable)
                   + CustomCodeValidation.diagnostics(document: doc, registry: registry)
```

- [ ] **Step 5: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter CustomCodeValidationTests`
Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): refuse scope breakers in user-written code

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 8: Cap runaway loops in codegen

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/LoopHardening.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Groups/GroupCodegen.swift` (the `.msl` branch from Task 6)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/ExpressionNode.swift` (`template(for:)`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LoopHardeningTests.swift`

**Interfaces:**
- Consumes: `MSLScanner.loopSites(in:)` (Task 2).
- Produces: `LoopHardening.harden(_ text: String) -> String`, and `LoopHardening.cap = 4096`.

**No loop form is refused** (spec §24.4). `while`, `do` and `for` are all allowed, including bounds that are parameters rather than literals — `for (int i = 0; i < n; i++)` over an iteration-count slider is the first loop anyone writes, and refusing it would leave no workaround inside the app. Instead the *emitted* text carries a counter and a `break`. **The user's own text is never rewritten**: `harden` runs on the way into the generated program, and the editor always shows exactly what was typed.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/LoopHardeningTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct LoopHardeningTests {
    @Test func aBodyWithNoLoopIsUnchanged() {
        let s = "out = in_a * 2.0;"
        #expect(LoopHardening.harden(s) == s)
    }

    @Test func aForLoopGainsACounterAndABreak() {
        let out = LoopHardening.harden("for (int i = 0; i < n; i++) { s += 1.0; }")
        #expect(out.contains("mn_loopGuard0"))
        #expect(out.contains("break"))
        #expect(out.contains("4096"))
        #expect(out.contains("i < n"))   // the user's own condition survives
    }

    @Test func whileAndDoAreHardenedNotRefused() {
        #expect(LoopHardening.harden("while (t > 0.0) { t -= 1.0; }").contains("mn_loopGuard0"))
        #expect(LoopHardening.harden("do { t -= 1.0; } while (t > 0.0);").contains("mn_loopGuard0"))
    }

    /// A bound that is a parameter rather than a literal is exactly the case the spec refuses to
    /// reject — it must be hardened like any other.
    @Test func aParameterBoundIsAllowed() {
        let out = LoopHardening.harden("for (int i = 0; i < in_count; i++) { s += 1.0; }")
        #expect(out.contains("in_count"))
        #expect(out.contains("mn_loopGuard0"))
    }

    /// Nested loops get one counter each. Sharing one would let an inner loop exhaust the outer
    /// loop's budget and terminate it early — a wrong answer rather than a slow one.
    @Test func nestedLoopsGetOneCounterEach() {
        let out = LoopHardening.harden("for (int i = 0; i < 4; i++) {\n  for (int j = 0; j < 4; j++) {\n    s += 1.0;\n  }\n}")
        #expect(out.contains("mn_loopGuard0"))
        #expect(out.contains("mn_loopGuard1"))
    }

    @Test func hardeningIsIdempotentInShape() {
        let once = LoopHardening.harden("while (a) { b(); }")
        #expect(once.components(separatedBy: "mn_loopGuard0").count - 1 >= 2)  // declared and incremented
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter LoopHardeningTests`
Expected: FAIL — no `LoopHardening`.

- [ ] **Step 3: Write the hardener**

Create `MetalNodesKit/Sources/MetalNodesCore/Codegen/LoopHardening.swift`:

```swift
import Foundation

/// A seatbelt on emitted loops (spec §24.4). Nothing correct is refused: every loop form is
/// allowed, including bounds that are parameters. The emitted text simply carries a counter and a
/// `break`, so a runaway loop terminates rather than hanging the GPU — which Metal's watchdog
/// would otherwise kill, taking the app with it.
///
/// The user's own text is never modified. This runs on the way into the generated program.
public enum LoopHardening {
    /// Deliberately generous: high enough that no plausible shader loop reaches it, low enough
    /// that hitting it costs milliseconds rather than a frozen device.
    public static let cap = 4096

    public static func harden(_ text: String) -> String {
        let sites = Set(MSLScanner.loopSites(in: text))
        guard !sites.isEmpty else { return text }

        var out: [String] = []
        var counter = 0
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard sites.contains(i) else { out.append(String(raw)); continue }
            let guardName = "mn_loopGuard\(counter)"
            counter += 1
            let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
            out.append("\(indent)int \(guardName) = 0;")
            out.append(String(raw))
            // The guard sits at the top of the body, so it runs on every iteration of any form.
            out.append("\(indent)  if (++\(guardName) > \(cap)) { break; }")
        }
        return out.joined(separator: "\n")
    }
}
```

The `break` is inserted as the first statement of the loop body, which works for `for`, `while` and `do` alike because all three open a braced block on the same line the scanner reports. A loop whose body is a single unbraced statement (`for (…) x += 1;`) is the one shape this misses — add a test for it and, if the emitted text is wrong, brace the body during hardening rather than refusing the loop.

- [ ] **Step 4: Apply it at both emission sites**

In `GroupCodegen`'s `.msl` branch (Task 6), harden before splicing:

```swift
        case .msl(let text):
            for decl in def.outputs {
                b.add("    \(concrete(decl.type).mslName) \(decl.name) = \(zeroLiteral(concrete(decl.type)));")
            }
            for line in LoopHardening.harden(text).split(separator: "\n", omittingEmptySubsequences: false) {
                b.add("    " + line)
            }
```

In `ExpressionNode.template(for:)`, harden the formula before wrapping it — a one-line expression cannot contain a loop today, but the call costs nothing and means the guarantee holds if the field ever becomes multi-line.

- [ ] **Step 5: Prove it on a GPU**

Everything above asserts on text. §24.9 asks for the claim that actually matters — a body whose loop would not terminate still produces a program that compiles and returns.

Create `MetalNodesKit/Tests/MetalNodesRenderTests/CustomCodeCompileTests.swift`:

```swift
import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct CustomCodeCompileTests {
    /// A body whose loop has no terminating condition of its own. Without hardening this is a
    /// hang; with it the program compiles, links, and the loop exits at the cap.
    @Test func aRunawayLoopStillProducesALinkedPipeline() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Runaway")
        def.inputs = [SocketDecl(name: "a", label: "A", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float))]
        def.body = .msl("while (a > 0.0) { out += 0.0001; }")
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let inst = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[inst.id] = inst
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(inst.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .fragment)
        #expect(shader.source.contains("mn_loopGuard0"))
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success = result else { Issue.record("compile failed: \(result)"); return }
    }

    /// The Expression node's substituted formula compiles too — the second custom-code path.
    @Test func anExpressionCompiles() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        var uv = NodeInstance(id: NodeID(), kind: .builtin("input.uv"), position: .zero)
        var e = NodeInstance(id: NodeID(), kind: .builtin(ExpressionNode.id), position: .zero)
        e.params[ExpressionNode.formulaParam] = .text("float4(uv, 0.5 * uv.x, 1.0)")
        e.params[ExpressionNode.outputTypeParam] = .enumCase("float4")
        for n in [terminal, uv, e] { g.nodes[n.id] = n }
        g.inputs[SocketRef(e.id, "uv")] = SocketRef(uv.id, "uv")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(e.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .fragment)
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success = result else { Issue.record("compile failed: \(result)"); return }
    }
}
```

Copy the device guard and the `compile(_:generation:)` call from `MaterialCompileTests.swift` verbatim — that file is the reference for how a GPU test skips on a machine with no device. Check `output.fragment`'s terminal socket name (`color`) and `input.uv`'s output socket name against `BuiltinNodes` before writing.

- [ ] **Step 6: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter LoopHardeningTests`
Run: `swift test --package-path MetalNodesKit --filter CustomCodeCompileTests`
Run: `swift test --package-path MetalNodesKit --filter CustomMSLEmissionTests`
Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests
git commit -m "feat(core): cap emitted loops instead of refusing them

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 9: Errors land on the user's line

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/LineMap.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/SourceBuilder.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Diagnostic.swift` (`Diagnostic` gains a user line)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (the `.failure` mapping)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LineMapTests.swift` (append; create if absent)
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/UserLineErrorTests.swift`

**Interfaces:**
- Consumes: `DefinitionBody` (Task 5), `LoopHardening.harden` (Task 8).
- Produces: `LineMap.UserEntry` + `LineMap.userEntries`; `LineMap.userLine(forLine:) -> Int?`; `LineMap.definition(forLine:) -> GroupID?`; `Diagnostic.userLine: Int?`.

`LineMap` maps a generated-program line to the node that produced it. When the emitter splices *N* lines of user text starting at program line *P*, the entry records *P*; a compiler diagnostic at *P+k* then resolves to line *k+1* of the user's own text. One field and one lookup — `ShaderCompiler.parseLines`, the diagnostics panel and the node outline are otherwise unchanged.

**One trap to get right.** Task 8's hardening *inserts lines* into the emitted text, so program line *P+k* no longer corresponds to user line *k+1*. `harden` must therefore return the line mapping alongside the text, and `SourceBuilder` records that rather than a flat offset.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/LineMapTests.swift` (or append):

```swift
import Testing
@testable import MetalNodesCore

@Suite struct UserLineMapTests {
    /// A definition whose body has a deliberate error on its third line.
    private func document() -> ShaderDocument {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl("float a = 1.0;\nfloat b = 2.0;\nout = nonexistent_fn(a, b);")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[t.id] = t; g.nodes[i.id] = i
        g.inputs[SocketRef(t.id, "color")] = SocketRef(i.id, "out")
        doc.root = g
        return doc
    }

    @Test func aProgramLineResolvesToTheUsersOwnLine() throws {
        let shader = try ShaderGenerator.generate(document())
        // Find the program line carrying the third user line.
        let lines = shader.source.split(separator: "\n", omittingEmptySubsequences: false)
        let programLine = try #require(lines.firstIndex { $0.contains("nonexistent_fn") }) + 1
        #expect(shader.lineMap.userLine(forLine: programLine) == 3)
    }

    @Test func aLineOutsideAnyUserBodyHasNoUserLine() throws {
        let shader = try ShaderGenerator.generate(document())
        #expect(shader.lineMap.userLine(forLine: 1) == nil)   // `#include <metal_stdlib>`
    }

    /// Hardening inserts lines, so a flat offset would drift. A loop before the error must not
    /// shift the reported user line.
    @Test func aHardenedLoopDoesNotShiftTheUserLine() throws {
        var doc = document()
        let gid = doc.definitions.keys.first!
        doc.definitions[gid]!.body = .msl("for (int i = 0; i < 4; i++) { }\nout = nonexistent_fn(1.0);")
        let shader = try ShaderGenerator.generate(doc)
        let lines = shader.source.split(separator: "\n", omittingEmptySubsequences: false)
        let programLine = try #require(lines.firstIndex { $0.contains("nonexistent_fn") }) + 1
        #expect(shader.lineMap.userLine(forLine: programLine) == 2)
    }
}
```

Create `MetalNodesKit/Tests/MetalNodesRenderTests/UserLineErrorTests.swift`:

```swift
import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct UserLineErrorTests {
    /// The end-to-end promise: a real Metal error on the user's third line is reported as line 3.
    @Test func aCompilerErrorCarriesTheUsersLineNumber() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl("float a = 1.0;\nfloat b = 2.0;\nout = nonexistent_fn(a, b);")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[t.id] = t; g.nodes[i.id] = i
        g.inputs[SocketRef(t.id, "color")] = SocketRef(i.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc)
        let compiler = try ShaderCompiler(device: device)
        guard case .failure(_, let lines, _) = await compiler.compile(shader, generation: 1) else {
            Issue.record("expected a compile failure"); return
        }
        let errors = lines.filter { $0.severity == .error }
        #expect(!errors.isEmpty)
        // Every error inside the user's body resolves to a line the user can see.
        let userLines = errors.compactMap { shader.lineMap.userLine(forLine: $0.line) }
        #expect(userLines.contains(3))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter UserLineMapTests`
Expected: FAIL — `LineMap` has no `userLine(forLine:)`.

- [ ] **Step 3: Carry the mapping through hardening**

Change `LoopHardening.harden` to return the text and the mapping, and keep a convenience for callers that do not need it:

```swift
    /// The hardened text plus, for each emitted line, the 0-based user line it came from —
    /// `nil` for a line the hardener inserted.
    public static func hardened(_ text: String) -> (text: String, userLines: [Int?]) {
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        let sites = Set(MSLScanner.loopSites(in: text))
        guard !sites.isEmpty else { return (text, Array(raw.indices)) }

        var out: [String] = []
        var origins: [Int?] = []
        var counter = 0
        for (i, line) in raw.enumerated() {
            guard sites.contains(i) else { out.append(String(line)); origins.append(i); continue }
            let guardName = "mn_loopGuard\(counter)"
            counter += 1
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            out.append("\(indent)int \(guardName) = 0;");                       origins.append(nil)
            out.append(String(line));                                          origins.append(i)
            out.append("\(indent)  if (++\(guardName) > \(cap)) { break; }");   origins.append(nil)
        }
        return (out.joined(separator: "\n"), origins)
    }

    public static func harden(_ text: String) -> String { hardened(text).text }
```

- [ ] **Step 4: Record the offset**

**Read `LineMap.swift` before writing this.** `Entry.node` is a non-optional `NodeID` and `Entry` is `Hashable` with `let` members; a Custom MSL definition's body belongs to a *definition*, not to any node instance, so it cannot become an `Entry`. User text therefore gets its own parallel array rather than an optional field on `Entry` — which also leaves `node(forLine:)` and `lines(for:)` untouched, so every M0–M7 line-map test keeps passing unchanged.

```swift
    /// Generated lines that came from text the user typed (spec §24.4).
    public struct UserEntry: Sendable, Hashable {
        public let range: ClosedRange<Int>
        /// For each line of `range`, the 0-based line of the user's own text it came from —
        /// `nil` for a line `LoopHardening` inserted.
        public let userLines: [Int?]
        /// The Expression node this text belongs to, or `nil` when it is a definition's body.
        public let node: NodeID?
        /// The Custom MSL definition this text belongs to, or `nil` for an Expression.
        public let definition: GroupID?
    }
    public var userEntries: [UserEntry] = []

    /// The 1-based line of the user's own text that generated `line`, or `nil` when `line` did
    /// not come from user-authored code.
    public func userLine(forLine line: Int) -> Int? {
        for e in userEntries where e.range.contains(line) {
            let i = line - e.range.lowerBound
            guard i >= 0, i < e.userLines.count, let u = e.userLines[i] else { return nil }
            return u + 1   // report 1-based, as compilers do
        }
        return nil
    }

    /// Which definition's body `line` came from, so the code editor can list only its own errors.
    public func definition(forLine line: Int) -> GroupID? {
        userEntries.first { $0.range.contains(line) }?.definition
    }
```

`SourceBuilder` gains one method that appends user text and records the entry. It reuses the private `append`, which already advances `nextLine`:

```swift
    /// Appends user-authored lines, recording which of the user's own lines each came from so a
    /// compiler diagnostic can be reported against the text the user actually typed (spec §24.4).
    /// `owner` and `definition` are mutually exclusive: an Expression has a node, a Custom MSL
    /// definition body has a definition.
    mutating func add(userText lines: [String], origins: [Int?],
                      owner: NodeID? = nil, definition: GroupID? = nil) {
        precondition(lines.count == origins.count)
        guard !lines.isEmpty else { return }
        let first = nextLine
        let last = append(lines.joined(separator: "\n"))
        map.userEntries.append(LineMap.UserEntry(range: first...last, userLines: origins,
                                                 node: owner, definition: definition))
        if let owner { own(first...last, owner) }
    }
```

`own` is private to `SourceBuilder` and already merges adjacent same-owner ranges, so an Expression's text still shows up in the node-outline highlight exactly as a template body does.

**The two call sites.** Both currently splice user text with plain `b.add`, and both change to `add(userText:origins:…)`:

1. `GroupCodegen`'s `.msl` branch (Task 6, hardened in Task 8) — replace the `for line in …harden(text)…` loop with:

```swift
            let hardened = LoopHardening.hardened(text)
            b.add(userText: hardened.text.split(separator: "\n", omittingEmptySubsequences: false)
                                          .map { "    " + $0 },
                  origins: hardened.userLines, definition: def.id)
```

2. `ExpressionNode`'s substitution (Task 4) — the formula is one line, so its origins are `[0]` and its owner is the node:

```swift
            b.add(userText: [statement], origins: [0], owner: node.id)
```

Emit indentation as part of each line, not as a separate `add`: a line the builder did not see is a line the map cannot number.

- [ ] **Step 5: Carry it into the diagnostic**

`Diagnostic` gains `public var userLine: Int?` and `public var definition: GroupID?`, both defaulted `nil` so every existing construction compiles. `definition` is what lets the code editor (Task 17) list only the open definition's own errors. In `EditorModel`'s `.failure` branch:

```swift
            for l in lines {
                let sev: Diagnostic.Severity = l.severity == .error ? .error : .warning
                var d = Diagnostic(sev, l.message, node: shader.lineMap.node(forLine: l.line))
                d.userLine = shader.lineMap.userLine(forLine: l.line)
                d.definition = shader.lineMap.definition(forLine: l.line)
                mapped.append(d)
            }
```

- [ ] **Step 6: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter UserLineMapTests`
Run: `swift test --package-path MetalNodesKit --filter UserLineErrorTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS, with `LineMapGroupTests` unmoved — an entry with no `userLines` behaves exactly as before.

```bash
git add MetalNodesKit/Sources MetalNodesKit/Tests
git commit -m "feat(core): map compile errors back to the user's own line

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 10: The legality predicate

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LegalityPredicateTests.swift`

**Interfaces:**
- Consumes: `MSLScanner` (Task 2).
- Produces: `EmitEnvironment.SysValue { spelling: String, readable: Bool }`; `EmitEnvironment.sys: [String: SysValue]`; `EmitEnvironment.Legality { allowed, missing(String) }`; `canEmit(_:chosen:) -> Legality`; `canEmit(mslText:) -> Legality`.

This task changes the *shape* of the vocabulary and adds the question, without yet moving any caller — Task 11 does that. Splitting them keeps the mechanical change reviewable apart from the behavioural one.

**Readable versus fill-only (spec §24.5).** `materialSys` supplies `resolution` and `mouse` as neutral literals so group-function argument lists still compile (§23.4). Mere presence therefore cannot mean legal, or Mouse and Resolution would silently become available under the RealityKit target. `SysValue.readable` is what today's hand-written refusal list becomes.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/LegalityPredicateTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct LegalityPredicateTests {
    private func body(_ t: String) -> NodeBody { .template(t) }

    @Test func aNodeReadingAKeyTheEnvironmentHasIsAllowed() {
        #expect(EmitEnvironment.fragment.canEmit(body("{out.x} = {sys.uv};"), chosen: nil) == .allowed)
        #expect(EmitEnvironment.realityKitSurface.canEmit(body("{out.x} = {sys.worldPosition};"), chosen: nil) == .allowed)
    }

    @Test func aNodeReadingAMissingKeyIsRefused() {
        #expect(EmitEnvironment.fragment.canEmit(body("{out.x} = {sys.worldPosition};"), chosen: nil)
                == .missing("worldPosition"))
        #expect(EmitEnvironment.realityKitGeometry.canEmit(body("{out.x} = {sys.tangent};"), chosen: nil)
                == .missing("tangent"))
    }

    /// The wrinkle §24.5 exists for: the material environments *do* spell `resolution` and
    /// `mouse`, as neutral literals for group-call argument lists — but a node may not read them.
    @Test func fillOnlyKeysArePresentButNotReadable() {
        #expect(EmitEnvironment.realityKitSurface.sys["resolution"] != nil)
        #expect(EmitEnvironment.realityKitSurface.sys["resolution"]?.readable == false)
        #expect(EmitEnvironment.realityKitSurface.canEmit(body("{out.x} = {sys.resolution};"), chosen: nil)
                == .missing("resolution"))
        #expect(EmitEnvironment.realityKitSurface.canEmit(body("{out.x} = {sys.mouse};"), chosen: nil)
                == .missing("mouse"))
    }

    @Test func theSameKeysStayReadableInTheFragmentEnvironment() {
        #expect(EmitEnvironment.fragment.sys["resolution"]?.readable == true)
        #expect(EmitEnvironment.fragment.canEmit(body("{out.x} = {sys.mouse};"), chosen: nil) == .allowed)
    }

    /// A `.variants` body is only as legal as the case actually chosen.
    @Test func variantsAreCheckedForTheChosenCaseOnly() {
        let b = NodeBody.variants(param: "mode", [
            "plain": "{out.x} = {sys.uv};",
            "aspect": "{out.x} = {sys.uv} * {sys.resolution};",
        ])
        #expect(EmitEnvironment.realityKitSurface.canEmit(b, chosen: "plain") == .allowed)
        #expect(EmitEnvironment.realityKitSurface.canEmit(b, chosen: "aspect") == .missing("resolution"))
    }

    /// Custom MSL names accessors textually rather than through a placeholder (spec §24.5).
    @Test func textualAccessorsAreCheckedAgainstTheEnvironment() {
        #expect(EmitEnvironment.realityKitSurface.canEmit(mslText: "out = params.geometry().normal().x;") == .allowed)
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = params.geometry().normal().x;")
                == .missing("params.geometry().normal()"))
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = in_a * 2.0;") == .allowed)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter LegalityPredicateTests`
Expected: FAIL to compile — `sys` is `[String: String]` and there is no `canEmit`.

- [ ] **Step 3: Reshape the vocabulary**

In `EmitEnvironment.swift`:

```swift
    /// One system value's spelling in this environment, and whether a node may *read* it.
    /// A fill-only value exists so group-function argument lists compile (§23.4) but is not
    /// something a node can name — that is how Mouse and Resolution stay refused under the
    /// RealityKit target while `mn_g_…(uv, time, size, mouse, …)` still type-checks.
    public struct SysValue: Sendable, Hashable {
        public let spelling: String
        public let readable: Bool
        public init(_ spelling: String, readable: Bool = true) {
            self.spelling = spelling; self.readable = readable
        }
    }

    public var sys: [String: SysValue]
```

Every existing `sys: ["uv": "in.uv", …]` literal becomes `["uv": SysValue("in.uv"), …]`. In `materialSys(for:)`, the two neutral literals become fill-only:

```swift
            "resolution": SysValue("float2(1.0, 1.0)", readable: false),
            "mouse": SysValue("float2(0.0, 0.0)", readable: false),
```

`Emitter` reads `env.sys[name]?.spelling` wherever it read `env.sys[name]`. That is a mechanical rename and must change no generated source — the golden suites are the gate.

- [ ] **Step 4: Add the predicate**

```swift
    public enum Legality: Equatable, Sendable {
        case allowed
        case missing(String)
    }

    /// Whether a node with this body can be emitted here: every `{sys.…}` name it *reads* must
    /// have a readable spelling in this environment (spec §24.5).
    public func canEmit(_ body: NodeBody, chosen: String?) -> Legality {
        let text: String
        switch body {
        case .template(let t): text = t
        case .variants(_, let table): text = chosen.flatMap { table[$0] } ?? ""
        case .custom: return .allowed   // a library escape hatch, not user text
        }
        for m in text.matches(of: NodeRegistry.placeholderPattern) where m.1 == "sys" {
            let name = String(m.2)
            guard let v = sys[name], v.readable else { return .missing(name) }
        }
        return .allowed
    }

    /// The same question for hand-written MSL, which names accessors textually (spec §24.5).
    /// The accessor set is derived from this environment's own readable spellings, so the two can
    /// never disagree.
    public func canEmit(mslText: String) -> Legality {
        let known = Set(sys.values.filter(\.readable).map(\.spelling))
        for accessor in MSLScanner.accessorCalls(in: mslText) where !known.contains(accessor) {
            if accessor.hasPrefix("params.") || accessor.hasPrefix("geo.") { return .missing(accessor) }
        }
        return .allowed
    }
```

Add `MSLScanner.accessorCalls(in:) -> [String]` — dotted call chains rooted at an identifier, e.g. `params.geometry().normal()`. Reuse the tokeniser: collect an identifier followed by one or more `.name()` groups, and return the joined text. Test it in `MSLScannerTests` alongside the others.

- [ ] **Step 5: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter LegalityPredicateTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS with **no golden movement** — this task only reshapes the vocabulary and adds a question nothing asks yet.

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): the emit environment can answer whether a node fits

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 11: Retire the four-way legality seam

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift` (`stages` becomes derived)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift` (drop the declarations)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/CustomCodeValidation.swift` (the third guard)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LegalityPredicateTests.swift` (append)

**Interfaces:**
- Consumes: `EmitEnvironment.canEmit` (Task 10); `CustomCodeValidation` (Task 7).
- Produces: `NodeDef.stages` computed from the environments rather than declared; `MaterialValidation.twoDimensionalOnly` and the derived `material3D` set deleted.

Handoff §14.6 records the seams between these four as the shared cause of two M7 defects. This is the task that removes them.

**The migration test is the point.** For every builtin, the derived stage set must equal what §23.3 declared by hand. That is what makes the refactor safe to land rather than hopeful, and it is the same shape as M7's correspondence test.

- [ ] **Step 1: Write the failing test**

Append to `LegalityPredicateTests.swift`:

```swift
@Suite struct DerivedStagesTests {
    /// What §23.3 declared by hand, before this task derived it. If a value here changes, either
    /// the vocabulary changed on purpose or the derivation is wrong — never edit this table to
    /// make the test pass.
    static let declared: [String: Set<MaterialStage>] = [
        "input.worldPosition": MaterialStage.all,
        "input.modelPosition": MaterialStage.all,
        "input.normal3d": MaterialStage.all,
        "input.bitangent": MaterialStage.all,
        "input.uv1": MaterialStage.all,
        "input.vertexColor": MaterialStage.all,
        "input.tangent": [.surface],
        "input.viewDirection": [.surface],
        "input.screenPosition": [.surface],
        "input.vertexID": [.geometry],
    ]

    @Test func everyDerivedStageSetMatchesWhatWasDeclared() {
        for (id, expected) in Self.declared {
            let def = NodeRegistry.builtin[id]
            #expect(def?.stages == expected, "\(id)")
        }
    }

    /// Every node that reads no stage-specific value is legal in both stages, and that must not
    /// have quietly changed either.
    @Test func stageAgnosticNodesStayAgnostic() {
        for id in ["math.mix", "noise.value", "input.float", "input.time", "input.uv", "color.invert"] {
            #expect(NodeRegistry.builtin[id]?.stages == MaterialStage.all, id)
        }
    }
}

@Suite struct LegalityRefactorTests {
    private func doc(_ nodeID: String, target: OutputTarget) -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.target = target
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin(GraphValidator.terminalID(for: target)), position: .zero)
        let n = NodeInstance(kind: .builtin(nodeID), position: .zero)
        g.nodes[terminal.id] = terminal; g.nodes[n.id] = n
        if let out = NodeRegistry.builtin[nodeID]?.outputs.first {
            let socket = target == .realityKit ? "baseColor" : "color"
            g.inputs[SocketRef(terminal.id, socket)] = SocketRef(n.id, out.name)
        }
        d.root = g
        return d
    }

    private func errors(_ d: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: d, registry: .builtin, target: d.settings.target)
            .filter { $0.severity == .error }
    }

    /// The behaviour §23.7 rules 2 and 3 gave, now produced by one predicate.
    @Test func mouseAndResolutionStayRefusedUnderRealityKit() {
        #expect(!errors(doc("input.mouse", target: .realityKit)).isEmpty)
        #expect(!errors(doc("input.resolution", target: .realityKit)).isEmpty)
    }

    @Test func threeDimensionalNodesStayRefusedUnderFragment() {
        #expect(!errors(doc("input.worldPosition", target: .fragment)).isEmpty)
        #expect(!errors(doc("input.vertexID", target: .fragment)).isEmpty)
    }

    @Test func legalCombinationsStayLegal() {
        #expect(errors(doc("input.worldPosition", target: .realityKit)).isEmpty)
        #expect(errors(doc("input.mouse", target: .fragment)).isEmpty)
        #expect(errors(doc("noise.value", target: .realityKit)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter DerivedStagesTests`
Expected: PASS at first — `stages` is still declared and still correct. That is the point: the table records today's truth *before* the derivation replaces it, so Step 3 has something to be measured against. Run it now and confirm it is green.

- [ ] **Step 3: Derive the stages**

In `NodeDef.swift`, `stages` stops being a stored property:

```swift
    /// Which RealityKit stages this node may appear in (spec §24.5). Derived from the emit
    /// environments rather than declared: a node is legal in a stage exactly when every
    /// `{sys.…}` name it reads has a readable spelling there. Declaring it separately is what
    /// let two M7 defects live in the seam.
    public var stages: Set<MaterialStage> {
        Set(MaterialStage.allCases.filter { stage in
            EmitEnvironment.materialEnvironment(for: stage).canEmit(body, chosen: defaultVariantCase) == .allowed
        })
    }
```

Add `EmitEnvironment.materialEnvironment(for:)` returning `.realityKitSurface` / `.realityKitGeometry`, and `NodeDef.defaultVariantCase` returning the `.variants` default so a variant body is judged on the case it will actually emit.

Remove the `stages:` parameter from `NodeDef.init` and every declaration in `Material3DNodes.swift`. Anything that passed `stages:` explicitly now derives it.

- [ ] **Step 4: Replace the static sets**

In `MaterialValidation.swift`, delete `twoDimensionalOnly` and the derived `material3D` set, and replace `targetDiagnostics` and `foreignNodeDiagnostics` with one rule driven by the predicate: for the target's environment (or each stage's, under `.realityKit`), ask `canEmit` of every reachable node's body and report `.missing(name)` as a diagnostic naming the node and what it reads.

The message must stay actionable. `"\(title) reads \(name), which the \(target.title) target does not provide"` covers both directions and replaces the two hand-written strings.

- [ ] **Step 5: Add the third custom-code guard**

In `CustomCodeValidation`, add the accessor check for `.msl` bodies:

```swift
            if case .msl(let text) = def.body,
               case .missing(let accessor) = environment(for: target).canEmit(mslText: text) {
                out.append(Diagnostic(.error, "\(def.name) uses \(accessor), which the \(target.title) target does not provide"))
            }
```

This requires `CustomCodeValidation.diagnostics` to take the target, so update its signature and the call site in `Validation.swift`.

- [ ] **Step 6: Run everything**

Run: `swift test --package-path MetalNodesKit --filter DerivedStagesTests`
Run: `swift test --package-path MetalNodesKit --filter LegalityRefactorTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialRuleTests`
Run: `swift test --package-path MetalNodesKit`

Expected: PASS throughout. `MaterialRuleTests` from M7 is the strongest regression gate here — it asserts every §23.7 behaviour, and this task must preserve all of it while deleting the code that produced it. If a message string changed, update the assertion; if a *behaviour* changed, the derivation is wrong.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "refactor(core): one legality predicate replaces three static sets

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 12: Live material parameters

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift` (`DocumentSettings.liveParameters`)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift` (`bakedUniforms`)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Export/MaterialExport.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LiveParametersTests.swift`

**Interfaces:**
- Consumes: `ParamValues`, `MaterialExport` (M7).
- Produces: `DocumentSettings.liveParameters: [ParamPath]` (ordered, at most four); the export spells a live parameter `params.uniforms().custom_parameter().x`.

A `CustomMaterial` exposes one `float4` (§23.6), so up to four floats animate from Swift without re-export. **The preview is deliberately unchanged** — it keeps reading the uniform buffer, because §23.6's baking was always a property of the export artifact, not of the graph.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/LiveParametersTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct LiveParametersTests {
    private func document(live: Int) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "liveMat"
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        var paths: [ParamPath] = []
        for i in 0..<max(live, 1) {
            var f = NodeInstance(kind: .builtin("input.float"), position: .zero)
            f.params["value"] = .float(Float(i) * 0.25)
            g.nodes[f.id] = f
            let socket = ["roughness", "metallic", "opacity", "specular", "occlusion"][i]
            g.inputs[SocketRef(terminal.id, socket)] = SocketRef(f.id, "out")
            paths.append(ParamPath(node: f.id, param: "value"))
        }
        doc.root = g
        doc.settings.liveParameters = Array(paths.prefix(live))
        return doc
    }

    @Test func settingsRoundTrip() throws {
        let doc = document(live: 2)
        let back = try JSONDecoder().decode(ShaderDocument.self, from: try JSONEncoder().encode(doc))
        #expect(back.settings.liveParameters == doc.settings.liveParameters)
    }

    @Test func settingsWithoutTheKeyDecodeAsEmpty() throws {
        let json = Data(#"{"fastMath":true,"exportName":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: json).liveParameters.isEmpty)
    }

    @Test func aLiveParameterReadsCustomParameterInTheExport() throws {
        let src = try #require(ShaderGenerator.generate(document(live: 2), target: .realityKit).exportSource)
        #expect(src.contains("params.uniforms().custom_parameter().x"))
        #expect(src.contains("params.uniforms().custom_parameter().y"))
    }

    @Test func aBakedParameterStillBakes() throws {
        let src = try #require(ShaderGenerator.generate(document(live: 0), target: .realityKit).exportSource)
        #expect(!src.contains("custom_parameter()"))
    }

    /// §23.6's baking is a property of the export, not of the graph — the preview keeps reading
    /// the uniform buffer whether a parameter is live or not.
    @Test func thePreviewIsUnchangedByMarkingAParameterLive() throws {
        let a = try ShaderGenerator.generate(document(live: 0), target: .realityKit).source
        let b = try ShaderGenerator.generate(document(live: 2), target: .realityKit).source
        #expect(a == b)
    }

    @Test func aFifthLiveParameterIsRefused() {
        var doc = document(live: 4)
        let extra = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        doc.settings.liveParameters.append(ParamPath(node: extra.id, param: "value"))
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(errs.contains { $0.message.lowercased().contains("four") })
    }

    @Test func theSwiftSnippetExposesTheLiveValues() throws {
        let files = try ShaderExport.files(for: document(live: 2))
        let swift = try #require(files.first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("custom.value"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter LiveParametersTests`
Expected: FAIL to compile — `DocumentSettings` has no `liveParameters`.

- [ ] **Step 3: Add the setting**

In `ShaderDocument.swift`, add to `DocumentSettings` and its `Keys`/`init(from:)`/`encode(to:)`, defaulting to empty via `decodeIfPresent`:

```swift
    /// Parameters that animate from Swift rather than baking into the exported `.metal`
    /// (spec §24.6). Ordered: index 0 is `custom_parameter().x`. At most four — a `CustomMaterial`
    /// exposes exactly one `float4`.
    public var liveParameters: [ParamPath] = []
```

- [ ] **Step 4: Spell them in the export**

`EmitEnvironment.bakedUniforms(layout:document:registry:)` gains the live list: for a field whose `path` appears in `document.settings.liveParameters`, the spelling is `params.uniforms().custom_parameter().<component>` at that index rather than a literal. Everything else bakes as before.

- [ ] **Step 5: Validate and document**

In `MaterialValidation`, refuse a fifth entry ("A RealityKit material exposes one float4 — at most four parameters can be live") and refuse a path whose field type is not `.float`. In `MaterialExport.header`, list live parameters separately from baked ones so the reader can see which is which; in `swiftSnippet`, add a setter writing `material.custom.value`.

- [ ] **Step 6: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter LiveParametersTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialExport`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS, including the existing `xcrun metal -c` and `swiftc -typecheck` export gates.

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): up to four material parameters animate from Swift

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 13: Clearcoat

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/MaterialStage.swift` (`MaterialLightingModel`)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift` (three sockets)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift` (setters, `liveSurfaceSockets`)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialPreviewCodegen.swift` (the second lobe)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Export/MaterialExport.swift` (availability note)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ClearcoatTests.swift`

**Interfaces:**
- Consumes: M7's material codegen.
- Produces: `MaterialLightingModel.clearcoat`; sockets `clearcoat`, `clearcoatRoughness`, `clearcoatNormal` on `output.material`.

§23.2 deferred clearcoat because it unlocked setters no socket produced. The sockets arrive here, so the model does too.

**Setters, verbatim from `RealityKitSurfaceShader.h`:** `set_clearcoat(half)`, `set_clearcoat_roughness(half)`, `set_clearcoat_normal(half3)`. All three are ignored unless the lighting model is clearcoat — the header's own doc comments say so — which is why `liveSurfaceSockets` gates them.

**The availability trap.** `set_clearcoat_normal` is iOS 18 / macOS 15+, unlike the rest of the surface API. When that socket is wired, the exported header carries an availability note and the Swift snippet's doc comment repeats it.

**The preview approximates clearcoat with a second, tighter specular lobe** over the base GGX response (spec §24.7) — crude but recognisable, and the inspector caption is extended to say so.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/ClearcoatTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct ClearcoatTests {
    private func document(_ model: MaterialLightingModel, wireClearcoatNormal: Bool = false) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.lightingModel = model
        doc.settings.exportName = "cc"
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.material"), position: .zero)
        var c = NodeInstance(kind: .builtin("input.float"), position: .zero)
        c.params["value"] = .float(0.7)
        g.nodes[t.id] = t; g.nodes[c.id] = c
        g.inputs[SocketRef(t.id, "clearcoat")] = SocketRef(c.id, "out")
        if wireClearcoatNormal {
            let n = NodeInstance(kind: .builtin("input.normal3d"), position: .zero)
            g.nodes[n.id] = n
            g.inputs[SocketRef(t.id, "clearcoatNormal")] = SocketRef(n.id, "normal")
        }
        doc.root = g
        return doc
    }

    @Test func theTerminalGainsThreeSockets() {
        let d = NodeRegistry.builtin["output.material"]!
        #expect(d.input(named: "clearcoat")?.type == .concrete(.float))
        #expect(d.input(named: "clearcoatRoughness")?.type == .concrete(.float))
        #expect(d.input(named: "clearcoatNormal")?.type == .concrete(.float3))
        #expect(BuiltinNodes.materialStages["clearcoat"] == .surface)
        #expect(BuiltinNodes.materialStages["clearcoatNormal"] == .surface)
    }

    @Test func theModelHasAClearcoatCase() {
        #expect(MaterialLightingModel.allCases.contains(.clearcoat))
        #expect(MaterialLightingModel.clearcoat.swiftCase == ".clearcoat")
    }

    /// The header is explicit: the three setters are ignored unless the model is clearcoat.
    @Test func theSettersAreEmittedOnlyUnderClearcoat() throws {
        let cc = try #require(ShaderGenerator.generate(document(.clearcoat), target: .realityKit).exportSource)
        #expect(cc.contains("set_clearcoat(half("))
        #expect(cc.contains("set_clearcoat_roughness(half("))

        let lit = try #require(ShaderGenerator.generate(document(.lit), target: .realityKit).exportSource)
        #expect(!lit.contains("set_clearcoat"))
    }

    @Test func clearcoatKeepsTheEightBaseSetters() throws {
        let cc = try #require(ShaderGenerator.generate(document(.clearcoat), target: .realityKit).exportSource)
        for s in ["set_base_color", "set_normal", "set_roughness", "set_metallic",
                  "set_emissive_color", "set_opacity", "set_ambient_occlusion", "set_specular"] {
            #expect(cc.contains(s), s)
        }
    }

    /// set_clearcoat_normal is iOS 18 / macOS 15+, unlike the rest of the surface API.
    @Test func theAvailabilityNoteAppearsOnlyWhenClearcoatNormalIsWired() throws {
        let wired = try ShaderExport.files(for: document(.clearcoat, wireClearcoatNormal: true))
        let metal = try #require(wired.first { $0.name.hasSuffix(".metal") })
        #expect(metal.contents.contains("iOS 18") || metal.contents.contains("macOS 15"))

        let bare = try ShaderExport.files(for: document(.clearcoat))
        let bareMetal = try #require(bare.first { $0.name.hasSuffix(".metal") })
        #expect(!bareMetal.contents.contains("iOS 18"))
    }

    @Test func thePreviewCarriesASecondLobeUnderClearcoat() throws {
        let cc = try ShaderGenerator.generate(document(.clearcoat), target: .realityKit).source
        #expect(cc.contains("mn_clearcoat"))
        let lit = try ShaderGenerator.generate(document(.lit), target: .realityKit).source
        #expect(!lit.contains("mn_clearcoat"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ClearcoatTests`
Expected: FAIL — no `.clearcoat` case, no sockets.

- [ ] **Step 3: Add the model and sockets**

`MaterialLightingModel` gains `case clearcoat` with `title` "Clearcoat" and `swiftCase` `.clearcoat`. Remove §23.2's comment explaining why it was absent and replace it with a pointer to §24.7.

In `Material3DNodes.swift`, add three inputs to `output.material` after `specular`:

```swift
                    SocketDecl(name: "clearcoat", label: "Clearcoat", type: .concrete(.float),
                               default: .value(.float(0))),
                    SocketDecl(name: "clearcoatRoughness", label: "Clearcoat Roughness", type: .concrete(.float),
                               default: .value(.float(0))),
                    SocketDecl(name: "clearcoatNormal", label: "Clearcoat Normal", type: .concrete(.float3),
                               default: .value(.float3(.init(0, 0, 1)))),
```

and to `materialStages`: all three `.surface`.

- [ ] **Step 4: Emit the setters**

`MaterialCodegen.setterStatement` gains three cases:

```swift
        case "clearcoat":          "surface.set_clearcoat(half(\(e)));"
        case "clearcoatRoughness": "surface.set_clearcoat_roughness(half(\(e)));"
        case "clearcoatNormal":    "surface.set_clearcoat_normal(half3(\(e)));"
```

`liveSurfaceSockets` gains the case:

```swift
        case .clearcoat: ["baseColor", "normal", "roughness", "metallic", "emissive", "opacity",
                          "occlusion", "specular", "clearcoat", "clearcoatRoughness", "clearcoatNormal"]
```

- [ ] **Step 5: The availability note**

In `MaterialExport.header`, when `clearcoatNormal` is wired, add:

```
// Clearcoat Normal requires iOS 18 / macOS 15 or later — set_clearcoat_normal is newer than
// the rest of the surface API. Remove that socket's wiring to target an earlier OS.
```

The Swift snippet's doc comment on `make()` repeats it. Both are gated on the same condition, so they cannot disagree.

- [ ] **Step 6: The preview's second lobe**

In `MaterialPreviewCodegen`, when the lighting model is `.clearcoat`, emit the two extra reads and a second GGX lobe over the base response:

```swift
    static let clearcoatHelper = """
    static inline float3 mn_clearcoatLobe(float3 n, float3 v, float3 l, float strength, float roughness) {
        float3 h = normalize(v + l);
        float a = max(roughness * roughness, 1e-3);
        float d = mn_ggx_distribution(saturate(dot(n, h)), a);
        float vis = mn_smith_visibility(saturate(dot(n, v)) + 1e-5, saturate(dot(n, l)), a);
        // A clearcoat is a thin dielectric: fixed F0 of 0.04, scaled by the coat's strength.
        return mn_schlick_fresnel(float3(0.04), saturate(dot(v, h))) * d * vis * strength;
    }
    """
```

and add its contribution to the returned colour. Extend the inspector caption (Task 18) to say clearcoat is the roughest part of the approximation.

- [ ] **Step 7: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter ClearcoatTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialCompileTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS. `MaterialCompileTests` must be extended with a `.clearcoat` case so the second lobe is GPU-compiled, and the `xcrun metal -c` export gate must cover a clearcoat document.

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests
git commit -m "feat(core): clearcoat sockets, lighting model and preview lobe

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 14: Custom attribute

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift` (`materialSys`)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift` (the setter)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialPreviewCodegen.swift` (interpolant + shims)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/CustomAttributeTests.swift`

**Interfaces:**
- Consumes: M7's material codegen.
- Produces: socket `customAttribute` (float4, geometry stage) on `output.material`; node `input.customAttribute` (float4, surface stage only).

`custom_attribute` is the **only** channel from the geometry stage to the surface stage (§23 preamble). Everything else the two stages share, they share by recomputing.

**The preview needs a real addition**, not just a shim accessor: `VertexOut` carries a `float4`, the generated vertex function writes it from the geometry stage's expression, and `MNSurfaceGeometry` reads it. Interpolation is Metal's default, matching RealityKit's documented behaviour.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/CustomAttributeTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct CustomAttributeTests {
    /// Writes a colour into customAttribute in the geometry stage and reads it back in the surface
    /// stage — the round trip the channel exists for.
    private func document() -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.material"), position: .zero)
        var c = NodeInstance(kind: .builtin("input.color"), position: .zero)
        c.params["value"] = .float4(.init(1, 0, 0, 1))
        let read = NodeInstance(kind: .builtin("input.customAttribute"), position: .zero)
        for n in [t, c, read] { g.nodes[n.id] = n }
        g.inputs[SocketRef(t.id, "customAttribute")] = SocketRef(c.id, "out")
        g.inputs[SocketRef(t.id, "baseColor")] = SocketRef(read.id, "value")
        doc.root = g
        return doc
    }

    @Test func theTerminalGainsAGeometrySocket() {
        #expect(NodeRegistry.builtin["output.material"]?.input(named: "customAttribute")?.type == .concrete(.float4))
        #expect(BuiltinNodes.materialStages["customAttribute"] == .geometry)
    }

    @Test func theReaderNodeIsSurfaceOnly() {
        let d = NodeRegistry.builtin["input.customAttribute"]
        #expect(d?.outputs.first?.type == .concrete(.float4))
        #expect(d?.stages == [.surface])
    }

    @Test func theExportWritesInGeometryAndReadsInSurface() throws {
        let src = try #require(ShaderGenerator.generate(document(), target: .realityKit).exportSource)
        #expect(src.contains("geo.set_custom_attribute("))
        #expect(src.contains("params.geometry().custom_attribute()"))
    }

    @Test func thePreviewCarriesItAsAnInterpolant() throws {
        let src = try ShaderGenerator.generate(document(), target: .realityKit).source
        #expect(src.contains("float4 customAttribute;"))
        #expect(src.contains("o.customAttribute ="))
        #expect(src.contains("in.customAttribute"))
    }

    /// Reading it in the geometry stage is refused — it does not exist there.
    @Test func readingItInTheGeometryStageIsRefused() {
        var doc = document()
        let t = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let read = doc.root.nodes.values.first { $0.kind == .builtin("input.customAttribute") }!
        doc.root.inputs[SocketRef(t.id, "baseColor")] = nil
        doc.root.inputs[SocketRef(t.id, "customAttribute")] = SocketRef(read.id, "value")
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(!errs.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter CustomAttributeTests`
Expected: FAIL — no socket, no node.

- [ ] **Step 3: Add the socket and the node**

In `Material3DNodes.swift`, add to `output.material` after `positionOffset`:

```swift
                    SocketDecl(name: "customAttribute", label: "Custom Attribute", type: .concrete(.float4),
                               default: .value(.float4(.init(0, 0, 0, 0)))),
```

with `materialStages["customAttribute"] = .geometry`, and add the reader to `material3D`:

```swift
        NodeDef(id: "input.customAttribute", title: "Custom Attribute", category: .input,
                outputs: [SocketDecl(name: "value", type: .concrete(.float4))],
                body: .template("{out.value} = {sys.customAttribute};")),
```

Its surface-only legality is now **derived** (Task 11): `customAttribute` appears only in the surface vocabulary, so no `stages:` is declared.

- [ ] **Step 4: Add the vocabulary and the setter**

In `materialSys(for:)`, add to the `.surface` branch only:

```swift
            s["customAttribute"] = SysValue("\(geo).custom_attribute()")
```

In `MaterialCodegen.setterStatement`:

```swift
        case "customAttribute": "geo.set_custom_attribute(\(e));"
```

- [ ] **Step 5: Carry it through the preview**

`MaterialPreviewCodegen.interpolantsStruct` gains `float4 customAttribute;`. The generated vertex function writes it from the geometry stage's `customAttribute` expression, defaulting to `float4(0.0)` when unwired. `MNSurfaceGeometry` gains `float4 custom_attribute() const { return in.customAttribute; }`.

Task 10's correspondence test then covers the new key automatically — that is the point of it.

- [ ] **Step 6: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter CustomAttributeTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialCompileTests`
Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests
git commit -m "feat(core): custom attribute carries a value from vertex to fragment

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 15: The Expression node's formula field

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/ParamControl.swift` (a `.text` case)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeGeometry.swift` (`bodyRows`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift` (`builtinPane`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (`diagnostics(for:)`)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/ExpressionEditorTests.swift`

**Interfaces:**
- Consumes: `ParamKind.text(multiline:)` and `ParamValue.text` (Task 1); `ExpressionNode.formulaParam` / `.shape(for:)` (Task 3); `Diagnostic.socket` (Task 7).
- Produces: `EditorModel.diagnostics(for: NodeID, socket: String?) -> [Diagnostic]`.

`ParamControl` currently switches over three `ParamKind` cases. Task 1 added a fourth, and nothing renders it yet — a `.text` param is invisible in the app until this task.

**Editing the formula reshapes the node.** `ExpressionNode.shape(for:)` derives inputs from the formula, so removing an identifier removes a socket, and any wire into it becomes dangling. `.setParam` is already classified `.topology` for a non-uniformable value (`DocumentChange.swift:65`), so undo and recompile are correct once `ParamValue.text.isUniformable` is `false` — Task 1 established that. What is *not* automatic is pruning the dangling edge: `apply` must drop edges whose target socket no longer exists in the new shape.

**Commit on submit, not per keystroke.** A half-typed formula (`a *`) is a compile error, and recompiling on every keystroke would flood the canvas with red. The field holds a local draft and commits on Return or focus loss — the same shape `SocketRow` and the export-name field already use.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesUITests/ExpressionEditorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

// `RecordingCompiler` is declared in `EditorModelTests.swift` — same test target, so it is
// visible here. Do not declare a second one.
@Suite @MainActor struct ExpressionEditorTests {
    private func model(formula: String) -> (EditorModel, NodeID) {
        var doc = ShaderDocument()
        var e = NodeInstance(kind: .builtin(ExpressionNode.id), position: .zero)
        e.params[ExpressionNode.formulaParam] = .text(formula)
        doc.root.nodes[e.id] = e
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        return (m, e.id)
    }

    @Test func theFormulaParamShowsInTheBody() {
        let decl = ExpressionNode.def.params.first { $0.name == ExpressionNode.formulaParam }
        #expect(decl?.showsInBody == true)
        if case .text(let multiline)? = decl?.kind { #expect(multiline == false) }
        else { Issue.record("formula is not a text param") }
    }

    /// A single-line text param takes exactly one row, like any other body param.
    @Test func aTextParamTakesTheRowsItNeeds() {
        let (m, id) = model(formula: "a + b")
        let shape = m.shape(of: m.document.root.nodes[id]!)
        // 2 inputs (a, b) + 2 body params (formula, type) + 1 output
        #expect(NodeGeometry.bodyRows(shape) == 5)
    }

    /// Editing the formula is a topology change: it adds and removes sockets.
    @Test func editingTheFormulaReshapesTheNode() {
        let (m, id) = model(formula: "a + b")
        #expect(m.shape(of: m.document.root.nodes[id]!).inputs.map(\.name) == ["a", "b"])
        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a * c")))
        #expect(m.shape(of: m.document.root.nodes[id]!).inputs.map(\.name) == ["a", "c"])
        #expect(m.undoManager.canUndo)
    }

    /// The wire into `b` has nowhere to land once `b` is gone. Leaving it would put an edge in the
    /// document naming a socket no shape declares — exactly the corruption class M7 closed.
    @Test func aWireIntoADroppedSocketIsPruned() {
        let (m, id) = model(formula: "a + b")
        var src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        src.params["value"] = .float(2)
        m.apply(.addNode(src))
        m.apply(.connect(from: SocketRef(src.id, "out"), to: SocketRef(id, "b")))
        #expect(m.document.root.inputs[SocketRef(id, "b")] != nil)

        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a * 2.0")))
        #expect(m.document.root.inputs[SocketRef(id, "b")] == nil)
        #expect(m.document.root.inputs[SocketRef(id, "a")] == nil)  // was never wired
    }

    /// Undo restores both the formula and the wire it dropped.
    @Test func undoRestoresThePrunedWire() {
        let (m, id) = model(formula: "a + b")
        var src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        src.params["value"] = .float(2)
        m.apply(.addNode(src))
        m.apply(.connect(from: SocketRef(src.id, "out"), to: SocketRef(id, "b")))
        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a")))
        m.undo()
        #expect(m.document.root.inputs[SocketRef(id, "b")] == SocketRef(src.id, "out"))
    }

    /// The field's own error text: diagnostics filed against the formula socket.
    @Test func diagnosticsFilterToTheFormulaSocket() {
        let (m, id) = model(formula: "a + b")
        m.diagnostics = [
            Diagnostic(.error, "use of undeclared identifier 'qq'", node: id,
                       socket: ExpressionNode.formulaParam),
            Diagnostic(.warning, "unrelated", node: id),
        ]
        let onField = m.diagnostics(for: id, socket: ExpressionNode.formulaParam)
        #expect(onField.count == 1)
        #expect(onField.first?.message.contains("qq") == true)
        #expect(m.diagnostics(for: id, socket: nil).count == 2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ExpressionEditorTests`
Expected: FAIL — no `diagnostics(for:socket:)`, and the dangling wire survives.

If `EditorModel(document:services:)` or `.testing` differs, copy the construction from `EditorModelTests.swift` — that file's helper is the reference.

- [ ] **Step 3: Prune edges the new shape no longer declares**

In `EditorModel.apply`, the `.setParam` branch, after writing the value:

```swift
        case .setParam(let node, let param, let value):
            document[path].nodes[node]?.params[param] = value
            // A param can change a node's shape (the Expression node's formula does, spec §24.2).
            // An edge into a socket the new shape does not declare would be unreachable and
            // uninspectable — prune it here, inside the same change, so undo restores both.
            if !value.isUniformable, let n = document[path].nodes[node] {
                let live = Set(shape(of: n, in: path).inputs.map(\.name))
                document[path].inputs = document[path].inputs.filter {
                    $0.key.node != node || live.contains($0.key.socket)
                }
            }
```

Use whatever spelling of `shape(of:in:)` the file already has — `document.shape(of:in:registry:)` at `EditorModel.swift:275`. The guard on `isUniformable` keeps this off the per-keystroke slider path, where the shape cannot change.

- [ ] **Step 4: Filter diagnostics for a socket**

`EditorModel.diagnostics` is `public private(set)` (`EditorModel.swift:46`), and `private(set)` is *not* relaxed by `@testable import` — the tests above assign to it, so widen it to `public internal(set)`. That keeps it read-only to the app and the UI views while letting the test target set up a diagnostic state without driving a whole compile. Then, in `EditorModel`:

```swift
    /// Diagnostics to show against one node, optionally narrowed to one socket or param.
    /// `Diagnostic.socket` is a plain `String?` (`Diagnostic.swift:8`) — there is no `SocketID`
    /// type. Passing `nil` returns every diagnostic on the node, socket-scoped ones included.
    public func diagnostics(for node: NodeID, socket: String? = nil) -> [Diagnostic] {
        diagnostics.filter { $0.node == node && (socket == nil || $0.socket == socket) }
    }
```

- [ ] **Step 5: Render a `.text` param**

In `ParamControl.body`, add the fourth case:

```swift
        case .text(let multiline):
            textField(multiline)
```

```swift
    /// A code field. It commits on Return or focus loss rather than per keystroke: a half-typed
    /// formula is a compile error, and recompiling on every character would flood the canvas with
    /// red (spec §24.2).
    @ViewBuilder
    private func textField(_ multiline: Bool) -> some View {
        let current: String = { if case .text(let s) = value { return s } else { return "" } }()
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(DraculaToken.muted.color)
            TextField(label, text: $draft, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 3...12 : 1)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { commitDraft() }
                .onChange(of: focused) { _, now in
                    onEditing?(now)
                    if !now { commitDraft() }
                }
                .focused($focused)
                .onAppear { draft = current }
                .onChange(of: current) { _, new in if !focused { draft = new } }
        }
    }

    private func commitDraft() {
        if case .text(let s) = value, s == draft { return }
        onChange(.text(draft))
    }
```

with `@State private var draft = ""` and `@FocusState private var focused: Bool` on `ParamControl`.

Autocorrection and autocapitalisation are off deliberately: iPadOS will otherwise capitalise `float3` and "correct" identifiers mid-formula.

- [ ] **Step 6: Give a multi-line text param its rows**

`NodeGeometry.bodyRows` counts one row per body param. A multi-line field needs more:

```swift
    static func bodyRows(_ shape: NodeShape) -> Int {
        let paramRows = shape.params.filter(\.showsInBody).reduce(0) { total, p in
            if case .text(let multiline) = p.kind, multiline { return total + 3 }
            return total + 1
        }
        return shape.inputs.count + paramRows + shape.outputs.count
    }
```

`utility.expression` is single-line, so this changes no current layout; it exists because Task 17's editor reuses the control.

- [ ] **Step 7: Show the error under the field**

In `InspectorView.builtinPane`, under each param control, render that param's diagnostics:

```swift
                    ForEach(model.diagnostics(for: id, socket: decl.name), id: \.self) { d in
                        Label(d.message, systemImage: d.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(d.severity == .error ? DraculaToken.red.color : DraculaToken.yellow.color)
                            .textSelection(.enabled)
                    }
```

`Diagnostic` is already `Hashable` (`Diagnostic.swift:3`), and the fields Task 9 adds are too, so `id: \.self` is valid without a new conformance.

- [ ] **Step 8: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter ExpressionEditorTests`
Run: `swift test --package-path MetalNodesKit --filter NodeGeometryTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS.

```bash
git add MetalNodesKit/Sources/MetalNodesUI MetalNodesKit/Tests/MetalNodesUITests
git commit -m "feat(ui): the Expression node's formula field, with its errors beneath it

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 16: Creating a Custom MSL definition

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Groups.swift` (`newCustomCodeDefinition`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/DocumentChange.swift` (`addDefinition`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift` (the menu item)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/CanvasContextMenu.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Palette/PaletteView.swift` (definitions section)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/CustomCodeEditorTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/CanvasContextMenuTests.swift` (extend)

**Interfaces:**
- Consumes: `DefinitionBody.msl` (Task 5); `GroupCodegen`'s `.msl` emission (Task 6).
- Produces: `DocumentChange.addDefinition(GroupDefinition)`; `EditorModel.newCustomCodeDefinition(at: CGPoint) -> GroupID?`; menu item **Node ▸ New Custom Code Node** (⌃⌘N).

Groups are always born from a selection (`groupSelection`), so nothing in the app creates an empty definition. A Custom MSL node has no selection to come from: it starts empty and the user writes into it.

**The starter body is a working shader, not a comment.** A new definition arrives with one `float` input `a`, one `float` output `out`, and a body that uses them, so the node compiles the moment it exists and the first edit is a change rather than a fill-in. The starter text is exactly:

```
// Your code runs inside a function. Inputs are parameters; assign to the outputs.
out = a * 2.0;
```

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesUITests/CustomCodeEditorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

@Suite @MainActor struct CustomCodeEditorTests {
    private func model() -> EditorModel {
        EditorModel(document: ShaderDocument(), compiler: RecordingCompiler())
    }

    @Test func aNewDefinitionStartsWithOneInputOneOutputAndAWorkingBody() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: CGPoint(x: 40, y: 40)))
        let def = try #require(m.document.definitions[id])
        #expect(def.inputs.map(\.name) == ["a"])
        #expect(def.outputs.map(\.name) == ["out"])
        guard case .msl(let body) = def.body else { Issue.record("not an msl body"); return }
        #expect(body.contains("out = a * 2.0;"))
    }

    /// It also places an instance — an invisible definition would be unreachable.
    @Test func creatingOnePlacesAnInstance() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: CGPoint(x: 40, y: 40)))
        let instances = m.document.root.nodes.values.filter { $0.kind == .group(id) }
        #expect(instances.count == 1)
        #expect(instances.first?.position == CGPoint(x: 40, y: 40))
    }

    /// The starter body compiles: the whole document validates with no errors.
    @Test func aNewDefinitionValidatesClean() throws {
        let m = model()
        _ = try #require(m.newCustomCodeDefinition(at: .zero))
        let errs = GraphValidator.validate(document: m.document, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
        #expect(errs.isEmpty, "\(errs.map(\.message))")
    }

    @Test func creatingOneIsASingleUndoStep() throws {
        let m = model()
        let before = m.document
        _ = try #require(m.newCustomCodeDefinition(at: .zero))
        m.undo()
        #expect(m.document.definitions.count == before.definitions.count)
        #expect(m.document.root.nodes.count == before.root.nodes.count)
    }

    /// Diving into a code definition is legal and lands on it.
    @Test func divingIntoACodeDefinitionOpensIt() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let instance = try #require(m.document.root.nodes.values.first { $0.kind == .group(id) })
        m.diveIn(instance.id)
        #expect(m.activePath == .definition(id))
        #expect(m.isEditingCode)
    }

    /// A graph definition is not code, and the code editor must not claim it.
    @Test func aGraphDefinitionIsNotEditingCode() {
        let m = model()
        var g = GroupDefinition(name: "G")
        g.body = .graph(Graph())
        m.apply(.addDefinition(g))
        m.editDefinition(g.id)
        #expect(m.activePath == .definition(g.id))
        #expect(!m.isEditingCode)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter CustomCodeEditorTests`
Expected: FAIL — no `newCustomCodeDefinition`, no `addDefinition`, no `isEditingCode`.

- [ ] **Step 3: Add the change case**

In `DocumentChange`:

```swift
    case addDefinition(GroupDefinition)
```

classified `.topology`, titled `"Add Node"`. In `EditorModel.apply`:

```swift
        case .addDefinition(let def):
            document.definitions[def.id] = def
```

- [ ] **Step 4: Create the definition and its instance**

In `EditorModel+Groups.swift`:

```swift
    /// A Custom MSL node is born empty — unlike a group, which is born from a selection (spec
    /// §24.3). It arrives with a working one-in/one-out body so it compiles before its first edit.
    public static let customCodeStarter = """
    // Your code runs inside a function. Inputs are parameters; assign to the outputs.
    out = a * 2.0;
    """

    @discardableResult
    public func newCustomCodeDefinition(at point: CGPoint) -> GroupID? {
        var def = GroupDefinition(name: uniqueDefinitionName("Custom Code"))
        def.inputs = [SocketDecl(name: "a", label: "A", type: .concrete(.float), default: .value(.float(0)))]
        def.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float))]
        def.body = .msl(Self.customCodeStarter)
        let instance = NodeInstance(kind: .group(def.id), position: point)
        // One change, so one undo step covers the definition and its instance together.
        apply(.insert(nodes: [instance], edges: [], definitions: [def], comments: []))
        return def.id
    }
```

Check `.insert`'s exact signature at `DocumentChange.swift:21` — it already carries `definitions:`, which is why it is the right case here and why `.addDefinition` is only needed for the test's graph-definition path. If `.insert` selects what it inserts, that is the wanted behaviour; if not, set `selection = [instance.id]` after applying.

Name deduplication already exists — `GroupOperations.uniqueDefinitionName(_:in:)` at `GroupOperations.swift:15`, which `groupSelection` uses. Call it rather than writing a second one:

```swift
        var def = GroupDefinition(name: GroupOperations.uniqueDefinitionName("Custom Code", in: document))
```

- [ ] **Step 5: Expose whether the open definition is code**

```swift
    /// True when the editor is inside a definition whose body is text rather than a graph — the
    /// canvas is replaced by the code editor (Task 17).
    public var isEditingCode: Bool {
        guard case .definition(let id) = activePath else { return false }
        if case .msl = document.definitions[id]?.body { return true }
        return false
    }
```

- [ ] **Step 6: Menu and context menu**

In `EditorCommands`, in the Node menu beside Group:

```swift
            Button("New Custom Code Node") { model?.requestCanvas(.newCustomCode) }
                .keyboardShortcut("n", modifiers: [.control, .command])
```

Routing through `requestCanvas` matches Paste and Add Sticky: the canvas knows where the viewport centre is, and the model does not. Add `.newCustomCode` to the canvas-request enum and handle it in `GraphCanvasView` by calling `model.newCustomCodeDefinition(at:)` with the same drop point Paste uses.

Add the same item to `CanvasContextMenu` in the empty-canvas section, and extend `CanvasContextMenuTests` to assert it appears there and not on a node's menu.

- [ ] **Step 7: Show code definitions in the palette**

`PaletteView`'s definitions section lists `document.definitions`. A `.msl` definition belongs there too — give its row a distinguishing symbol (`chevron.left.forwardslash.chevron.right`) so code and group definitions are told apart at a glance. Nothing else changes: instances are placed by the same `addInstance(of:at:)`.

- [ ] **Step 8: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter CustomCodeEditorTests`
Run: `swift test --package-path MetalNodesKit --filter CanvasContextMenuTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS.

```bash
git add MetalNodesKit/Sources/MetalNodesUI MetalNodesKit/Tests/MetalNodesUITests
git commit -m "feat(ui): create a Custom Code node, definition and instance in one step

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 17: The code editor, with errors on the user's line

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/CodeEditorView.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift` (swap the canvas)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorViewPad.swift` (same swap)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView+Groups.swift` (`DefinitionPane` socket editing for a code definition)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/DocumentChange.swift` (`setDefinitionBody`)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/CustomCodeEditorTests.swift` (append)

**Interfaces:**
- Consumes: `isEditingCode` (Task 16); `Diagnostic.userLine` (Task 9); `MSLHighlighter.attributed(_:highlightLines:)` (M6).
- Produces: `DocumentChange.setDefinitionBody(GroupID, String)`; `CodeEditorView`; `EditorModel.codeDiagnostics(for: GroupID) -> [(line: Int, message: String, severity: Severity)]`.

Diving into a code definition replaces the canvas with a text editor. Everything else stays: the breadcrumb, the inspector (which edits the definition's sockets), the preview, the generated-code panel.

**The error list is the deliverable, not the gutter.** A SwiftUI `TextEditor` gives no per-line decoration without dropping to `NSTextView`/`UITextView`, which is a platform-pair's worth of work for a coloured stripe. §24.4 asks for errors *at the user's line*; a list beneath the editor reading `3: use of undeclared identifier 'qq'`, where clicking a row selects that line, delivers that. The gutter is a §25 idea, and the plan says so rather than pretending otherwise.

**Line numbers come from `Diagnostic.userLine`** (Task 9), which is 1-based in the user's own text — the whole point of that task. A diagnostic with a `nil` `userLine` belongs to generated scaffolding and is filed under line 0, shown as "in generated code".

- [ ] **Step 1: Write the failing test**

Append to `CustomCodeEditorTests.swift`:

```swift
@Suite @MainActor struct CodeEditorTests {
    private func model() -> (EditorModel, GroupID) {
        let m = EditorModel(document: ShaderDocument(), compiler: RecordingCompiler())
        let id = m.newCustomCodeDefinition(at: .zero)!
        return (m, id)
    }

    @Test func editingTheBodyIsOneUndoableChange() throws {
        let (m, id) = model()
        m.apply(.setDefinitionBody(id, "out = a;"))
        guard case .msl(let b) = try #require(m.document.definitions[id]).body else {
            Issue.record("not an msl body"); return
        }
        #expect(b == "out = a;")
        m.undo()
        guard case .msl(let back) = try #require(m.document.definitions[id]).body else {
            Issue.record("not an msl body"); return
        }
        #expect(back == EditorModel.customCodeStarter)
    }

    /// The user typed three lines; the compiler complained about the third. The row says 3.
    @Test func diagnosticsAreListedAtTheUsersOwnLineNumbers() throws {
        let (m, id) = model()
        var d = Diagnostic(.error, "use of undeclared identifier 'qq'")
        d.userLine = 3
        m.diagnostics = [d]
        let rows = m.codeDiagnostics(for: id)
        #expect(rows.count == 1)
        #expect(rows.first?.line == 3)
        #expect(rows.first?.message.contains("qq") == true)
    }

    /// A diagnostic with no user line came from generated scaffolding, not from the user's text.
    @Test func aDiagnosticWithNoUserLineIsFiledAtZero() throws {
        let (m, id) = model()
        m.diagnostics = [Diagnostic(.warning, "unused variable 'p'")]
        #expect(m.codeDiagnostics(for: id).first?.line == 0)
    }

    /// Rows come back in line order, so the list reads top-to-bottom like the text does.
    @Test func rowsAreSortedByLine() throws {
        let (m, id) = model()
        var a = Diagnostic(.error, "second"); a.userLine = 7
        var b = Diagnostic(.error, "first"); b.userLine = 2
        m.diagnostics = [a, b]
        #expect(m.codeDiagnostics(for: id).map(\.line) == [2, 7])
    }

    /// The definition's own body text is what the editor shows — never a hardened or rewritten
    /// version of it (Global Constraints; spec §24.4).
    @Test func theEditorShowsExactlyWhatWasTyped() throws {
        let (m, id) = model()
        let typed = "for (int i = 0; i < 100000; ++i) { out += a; }"
        m.apply(.setDefinitionBody(id, typed))
        #expect(m.codeBody(for: id) == typed)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter CodeEditorTests`
Expected: FAIL — no `setDefinitionBody`, no `codeDiagnostics`, no `codeBody`.

- [ ] **Step 3: The change case and the accessors**

In `DocumentChange`:

```swift
    case setDefinitionBody(GroupID, String)
```

classified `.topology` (the body decides what the function computes and what identifiers it needs), titled `"Edit Code"`. In `apply`:

```swift
        case .setDefinitionBody(let id, let text):
            document.definitions[id]?.body = .msl(text)
```

In `EditorModel`:

```swift
    public func codeBody(for id: GroupID) -> String {
        if case .msl(let s)? = document.definitions[id]?.body { return s }
        return ""
    }

    /// The error list under the code editor. `userLine` is 1-based in the user's own text; a
    /// diagnostic without one came from generated scaffolding and sorts to the top as line 0.
    /// A diagnostic naming *another* definition is not this editor's problem and is dropped;
    /// one naming no definition at all is kept, because a body that fails to compile often
    /// reports against the function's signature line rather than inside the spliced text.
    public func codeDiagnostics(for id: GroupID)
        -> [(line: Int, message: String, severity: Diagnostic.Severity)] {
        diagnostics
            .filter { $0.definition == nil || $0.definition == id }
            .map { (line: $0.userLine ?? 0, message: $0.message, severity: $0.severity) }
            .sorted { $0.line < $1.line }
    }
```

- [ ] **Step 4: The editor view**

Create `MetalNodesKit/Sources/MetalNodesUI/Editor/CodeEditorView.swift`:

```swift
import SwiftUI
import MetalNodesCore

/// What replaces the canvas while a Custom MSL definition is open (spec §24.3, §24.4). The text
/// is the definition's body verbatim; the list beneath it carries the compiler's complaints at
/// the user's own line numbers.
struct CodeEditorView: View {
    let model: EditorModel
    let definition: GroupID

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .background(DraculaToken.background.color)
                .focused($focused)
                .onAppear { draft = model.codeBody(for: definition) }
                .onChange(of: definition) { _, id in draft = model.codeBody(for: id) }
                .onChange(of: focused) { _, now in if !now { commit() } }
            Divider()
            diagnosticsList
        }
        .background(DraculaToken.background.color)
        .onDisappear { commit() }
    }

    /// Committing on focus loss rather than per keystroke: a half-typed statement is a compile
    /// error, and recompiling on every character would fill this list with noise about text the
    /// user is still writing.
    private func commit() {
        guard draft != model.codeBody(for: definition) else { return }
        model.apply(.setDefinitionBody(definition, draft))
    }

    @ViewBuilder
    private var diagnosticsList: some View {
        let rows = model.codeDiagnostics(for: definition)
        if rows.isEmpty {
            HStack {
                Text("No problems").font(.caption).foregroundStyle(DraculaToken.muted.color)
                Spacer()
                Text("⌘S compiles — the preview updates when the code is valid")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            }
            .padding(8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.line > 0 ? "\(row.line)" : "—")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(DraculaToken.muted.color)
                                .frame(width: 24, alignment: .trailing)
                            Text(row.line > 0 ? row.message : "in generated code: \(row.message)")
                                .font(.caption2)
                                .foregroundStyle(row.severity == .error
                                                 ? DraculaToken.red.color : DraculaToken.yellow.color)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 120)
        }
    }
}
```

Check `DraculaToken`'s member names against `DraculaTheme.swift` — the panel uses `.background`, `.muted`, `.surface`; use whatever that file actually spells for red and yellow.

- [ ] **Step 5: Swap it in for the canvas**

In `EditorView` and `EditorViewPad`, where `GraphCanvasView` is placed:

```swift
            if model.isEditingCode, case .definition(let id) = model.activePath {
                CodeEditorView(model: model, definition: id)
            } else {
                GraphCanvasView(model: model)
            }
```

The breadcrumb, inspector, preview and code panel are outside this branch and keep working unchanged. Exiting with the breadcrumb or **Exit Group** returns to the canvas, so no new navigation is needed.

- [ ] **Step 6: The inspector edits its sockets**

`DefinitionPane` already lists a definition's inputs and outputs with rename/remove and an add button (`InspectorView+Groups.swift:105-201`) — that is exactly the socket editor a code definition needs, and it works on `def.inputs`/`def.outputs` without touching `def.graph`. Verify it does not read the graph anywhere; if it does (for example to check whether a socket is used before removing), guard that check with `if case .graph = def.body` so a code definition skips it.

A code definition's sockets *are* its function signature: renaming an input renames the parameter the user's text reads. Add a caption to the pane when the body is `.msl`:

```swift
                Text("Input names are the variables your code reads; output names are what it assigns to.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
```

- [ ] **Step 7: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter CodeEditorTests`
Run: `swift test --package-path MetalNodesKit --filter CustomCodeEditorTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS.

```bash
git add MetalNodesKit/Sources/MetalNodesUI MetalNodesKit/Tests/MetalNodesUITests
git commit -m "feat(ui): the Custom Code editor, with errors at the user's own line numbers

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 18: The inspector's live parameters and clearcoat caption

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift` (`documentSettings`, `builtinPane`)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/LiveParameterMarkingTests.swift`

**Interfaces:**
- Consumes: `DocumentSettings.liveParameters` (Task 12); `MaterialLightingModel.clearcoat` (Task 13).
- Produces: `EditorModel.toggleLiveParameter(_: ParamPath) -> Bool`; `EditorModel.liveParameterIndex(of: ParamPath) -> Int?`.

Task 12 gave live parameters a representation and an export spelling. Nothing sets them yet. The marking is per-parameter, in the inspector, on a float param of a node feeding the material terminal — so it belongs next to the control, not in a document-wide list.

**Four is a hard cap, and the UI says why.** A `CustomMaterial` exposes one `float4` (§23.6), which is four floats and not five. `toggleLiveParameter` returns `false` and posts a notice when the fifth is asked for; the settings section lists the four in order with the component each one lands in, so `custom_parameter().z` is traceable back to a node without reading the export.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesUITests/LiveParameterMarkingTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

@Suite @MainActor struct LiveParameterMarkingTests {
    private func model(floats: Int) -> (EditorModel, [ParamPath]) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var paths: [ParamPath] = []
        for i in 0..<floats {
            var f = NodeInstance(kind: .builtin("input.float"), position: CGPoint(x: Double(i) * 20, y: 0))
            f.params["value"] = .float(Float(i))
            doc.root.nodes[f.id] = f
            paths.append(ParamPath(node: f.id, param: "value"))
        }
        return (EditorModel(document: doc, compiler: RecordingCompiler()), paths)
    }

    @Test func markingAParamAddsItInOrder() {
        let (m, p) = model(floats: 3)
        #expect(m.toggleLiveParameter(p[0]))
        #expect(m.toggleLiveParameter(p[2]))
        #expect(m.document.settings.liveParameters == [p[0], p[2]])
        #expect(m.liveParameterIndex(of: p[2]) == 1)
        #expect(m.liveParameterIndex(of: p[1]) == nil)
    }

    @Test func markingAgainUnmarksAndClosesTheGap() {
        let (m, p) = model(floats: 3)
        for path in p { _ = m.toggleLiveParameter(path) }
        #expect(m.toggleLiveParameter(p[0]))
        #expect(m.document.settings.liveParameters == [p[1], p[2]])
        #expect(m.liveParameterIndex(of: p[2]) == 1)
    }

    /// A CustomMaterial exposes one float4 — four floats, not five (spec §23.6, §24.5).
    @Test func theFifthIsRefusedWithANotice() {
        let (m, p) = model(floats: 5)
        for path in p.prefix(4) { #expect(m.toggleLiveParameter(path)) }
        #expect(!m.toggleLiveParameter(p[4]))
        #expect(m.document.settings.liveParameters.count == 4)
        #expect(m.notice != nil)
    }

    @Test func markingIsUndoable() {
        let (m, p) = model(floats: 2)
        _ = m.toggleLiveParameter(p[0])
        m.undo()
        #expect(m.document.settings.liveParameters.isEmpty)
    }

    /// Deleting a marked node must not leave a live parameter pointing at nothing.
    @Test func deletingAMarkedNodeDropsItsLiveParameter() {
        let (m, p) = model(floats: 2)
        _ = m.toggleLiveParameter(p[0])
        _ = m.toggleLiveParameter(p[1])
        m.apply(.removeNodes([p[0].node]))
        #expect(m.document.settings.liveParameters == [p[1]])
    }

    /// The component letter shown beside each marked param, and used by the export.
    @Test func componentLettersFollowTheOrder() {
        #expect(EditorModel.liveParameterComponent(0) == "x")
        #expect(EditorModel.liveParameterComponent(3) == "w")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter LiveParameterMarkingTests`
Expected: FAIL — no `toggleLiveParameter`.

- [ ] **Step 3: The model methods**

In `EditorModel` (a new `EditorModel+LiveParameters.swift` if `EditorModel.swift` is already long):

```swift
    static let liveParameterLimit = 4

    static func liveParameterComponent(_ index: Int) -> String {
        ["x", "y", "z", "w"][index]
    }

    public func liveParameterIndex(of path: ParamPath) -> Int? {
        document.settings.liveParameters.firstIndex(of: path)
    }

    /// Marks or unmarks one float parameter as live. Returns false — with a notice — when the
    /// float4 a CustomMaterial exposes is already full (spec §23.6, §24.5).
    @discardableResult
    public func toggleLiveParameter(_ path: ParamPath) -> Bool {
        var s = document.settings
        if let i = s.liveParameters.firstIndex(of: path) {
            s.liveParameters.remove(at: i)
        } else {
            guard s.liveParameters.count < Self.liveParameterLimit else {
                showNotice("A material exposes four live values; unmark one first")
                return false
            }
            s.liveParameters.append(path)
        }
        apply(.setSettings(s))
        return true
    }
```

`.setSettings` is already undoable and already drives recompile through Task 12's addition to the recompile condition — `everySettingThatReachesCodegenRecompiles` (added in M7's debt work) will fail if `liveParameters` was left out of it, which is the check working as designed.

- [ ] **Step 4: Drop live parameters for deleted nodes**

In `apply`, the `.removeNodes` branch, after the nodes go:

```swift
            // A live parameter naming a node that no longer exists would emit a read of a value
            // nothing writes.
            document.settings.liveParameters.removeAll { ids.contains($0.node) }
```

Do the same wherever `.restore` or a definition delete can remove nodes — or, more robustly, add one `pruneLiveParameters()` called at the end of `apply` for `.topology` changes, which cannot miss a case:

```swift
    private func pruneLiveParameters() {
        let live = Set(document.root.nodes.keys)
        document.settings.liveParameters.removeAll { !live.contains($0.node) }
    }
```

Prefer the second: it is one call site rather than four, and the test above passes either way.

- [ ] **Step 5: The marking control**

In `InspectorView.builtinPane`, beside a float param when the target is `.realityKit`:

```swift
                    if model.document.settings.target == .realityKit, decl.isLiveable {
                        let path = ParamPath(node: id, param: decl.name)
                        let index = model.liveParameterIndex(of: path)
                        Toggle(isOn: Binding(get: { index != nil },
                                             set: { _ in model.toggleLiveParameter(path) })) {
                            HStack(spacing: 4) {
                                Text("Live")
                                if let i = index {
                                    Text("custom_parameter().\(EditorModel.liveParameterComponent(i))")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(DraculaToken.muted.color)
                                }
                            }
                        }
                        .toggleStyle(.checkbox_or_switch)
                        .font(.caption)
                    }
```

`.toggleStyle(.checkbox)` is macOS-only — use `#if os(macOS)` around the modifier or drop it entirely and let each platform's default apply.

`isLiveable` stays a private helper on `InspectorView`, not a new member on `ParamDecl`: this task touches only UI files, and one component of a `float4` holds exactly one float.

```swift
    private func isLiveable(_ decl: ParamDecl) -> Bool {
        if case .value(.float, _) = decl.kind { return true }
        return false
    }
```

so the condition above reads `model.document.settings.target == .realityKit, isLiveable(decl)`.

- [ ] **Step 6: The settings section**

In `documentSettings`, under the RealityKit branch, list the marked parameters in order — component letter, node title, param label — each with a button that unmarks it. This is the only place all four are visible at once, and it is what makes `custom_parameter().z` traceable.

Extend the lighting-model picker to carry `.clearcoat` (`allCases` already drives it, so it appears automatically once Task 13 lands) and add the caption beneath it:

```swift
                    if s.lightingModel == .clearcoat {
                        Text("The preview approximates the coat with a second specular lobe; the exported material is exact.")
                            .font(.caption2).foregroundStyle(DraculaToken.muted.color)
                    }
```

- [ ] **Step 7: Run the tests and commit**

Run: `swift test --package-path MetalNodesKit --filter LiveParameterMarkingTests`
Run: `swift test --package-path MetalNodesKit --filter EditorModelTests`
Run: `swift test --package-path MetalNodesKit`
Expected: PASS, `everySettingThatReachesCodegenRecompiles` included.

```bash
git add MetalNodesKit/Sources/MetalNodesUI MetalNodesKit/Tests/MetalNodesUITests
git commit -m "feat(ui): mark up to four live material parameters; caption the clearcoat preview

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 19: Integration — builds, the in-app checklist, and the record

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/SampleDocuments.swift` (a custom-code sample)
- Modify: `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` (§15)
- Modify: `/Users/maxburger/.claude/projects/-Users-maxburger-Developer-MetalNodes/memory/metalnodes-project-state.md` and `MEMORY.md`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/SampleDocumentTests.swift` (extend)

**Interfaces:**
- Consumes: every prior task.
- Produces: nothing new in code. This task is the gate between "the tests pass" and "the milestone shipped".

M7's most expensive defects — the depth attachment, the missing `params` in the vertex function — passed every test and failed on launch. **Four green builds and a checklist run by a human are the acceptance criteria for this milestone**, exactly as they were for M7 (handoff §14.3).

- [ ] **Step 1: A sample document that exercises both new node kinds**

Add to `SampleDocuments`:

```swift
    /// A RealityKit material whose roughness comes from an Expression and whose base colour goes
    /// through a Custom Code node — the two M8 features in one document, so the in-app checklist
    /// and the compile tests both have something real to open.
    public static func customCodeSample() -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "customCodeSample"

        // A Custom Code definition that tints its input.
        var tint = GroupDefinition(name: "Tint")
        tint.inputs = [SocketDecl(name: "c", label: "Color", type: .concrete(.float3),
                                  default: .value(.float3(.init(1, 1, 1))))]
        tint.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float3))]
        tint.body = .msl("out = c * float3(1.0, 0.85, 0.7);")
        doc.definitions[tint.id] = tint

        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.material"), position: CGPoint(x: 520, y: 120))
        var base = NodeInstance(kind: .builtin("input.color"), position: CGPoint(x: 60, y: 60))
        base.params["value"] = .float4(.init(0.2, 0.5, 0.9, 1))
        let tinted = NodeInstance(kind: .group(tint.id), position: CGPoint(x: 280, y: 60))

        // roughness = clamp(uv.x, 0.05, 0.95) — one Expression over one input.
        var uv = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 60, y: 240))
        var expr = NodeInstance(kind: .builtin(ExpressionNode.id), position: CGPoint(x: 280, y: 240))
        expr.params[ExpressionNode.formulaParam] = .text("clamp(uv.x, 0.05, 0.95)")
        expr.params[ExpressionNode.outputTypeParam] = .enumCase("float")

        for n in [terminal, base, tinted, uv, expr] { g.nodes[n.id] = n }
        g.inputs[SocketRef(tinted.id, "c")] = SocketRef(base.id, "out")
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(tinted.id, "out")
        g.inputs[SocketRef(expr.id, "uv")] = SocketRef(uv.id, "uv")
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(expr.id, "out")
        doc.root = g
        return doc
    }
```

Check the exact node ids and socket names against `BuiltinNodes` before writing this — `input.color`'s output socket and `input.uv`'s output socket are whatever that file spells, and a sample document that does not validate is worse than none. If `input.color` produces a `float4` where the definition wants a `float3`, insert the swizzle node the library already has rather than widening the definition's socket.

Extend `SampleDocumentTests` to assert it validates clean and generates for both `.realityKit` and `.fragment`, the same way the existing samples are asserted.

- [ ] **Step 2: Four builds, all green**

```bash
swift build --package-path MetalNodesKit 2>&1 | grep -c warning:   # must print 0
swift test --package-path MetalNodesKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MetalNodes.xcodeproj -scheme MetalNodes \
  -destination 'platform=macOS' build 2>&1 | tail -20
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MetalNodes.xcodeproj -scheme MetalNodes \
  -destination 'generic/platform=iOS' build 2>&1 | tail -20
git checkout -- MetalNodes.xcodeproj/project.pbxproj
git status --short   # must not list project.pbxproj
```

The `git checkout` is not optional and not a cleanup step you can defer: Xcode rewrites `project.pbxproj` on every build, and committing it is the one file-level mistake this project has made repeatedly.

- [ ] **Step 3: Run the M8 in-app checklist**

Launch the macOS app and walk it. Each line is a claim the tests cannot make.

1. **Expression, happy path.** New document, add an Expression node, type `a * b + 0.5`. Two sockets appear, named `a` and `b`. Wire two floats in, wire the output to the fragment terminal. The preview updates and the generated-code panel shows the formula inlined.
2. **Expression, error path.** Change the formula to `a * qq`. A red message appears under the field naming `qq`. The preview keeps its last good frame rather than going black.
3. **Expression, reshape.** Change it back to `a * b`. The `qq` socket disappears; the wire that fed it is gone; ⌘Z brings both back.
4. **Custom Code, creation.** ⌃⌘N. A node appears with one input and one output, and the preview still renders.
5. **Custom Code, editing.** Dive in. The canvas is replaced by the code editor showing the starter body. Change it to something with a deliberate typo on the third line. Click out. The list beneath says **3** and names the identifier.
6. **Custom Code, sockets.** With the definition open, add an output in the inspector, assign to it in the code, wire it up on the parent canvas. It carries a value.
7. **Custom Code, instances.** Place a second instance from the palette. Edit the definition once; both instances change. The generated code contains the function **once**.
8. **Loop cap.** Write `for (int i = 0; i < 100000000; ++i) { out += a * 0.0000001; }`. The app does not hang, the editor still shows the loop exactly as typed, and the generated-code panel shows the capped form.
9. **Scope breaker.** Write `out = a; }` and confirm the guard refuses it with a message naming the problem, rather than emitting broken MSL.
10. **Clearcoat.** RealityKit target, lighting model Clearcoat, wire Clearcoat to `0.8`. The preview gains a visible sheen and the caption about the approximation is present.
11. **Custom attribute.** Wire a colour into Custom Attribute and read it back through the Custom Attribute node into Base Color. The preview shows the colour, interpolated across the mesh.
12. **Live parameters.** Mark two floats live. The settings section lists them as `.x` and `.y`. Export; the header names them and the `.metal` reads `custom_parameter()`.
13. **Migration.** Open the recovered `Test.mnshader` and one M6-era document. Both open, render, and their generated MSL is unchanged from before this milestone.

Record the result of every line in handoff §15.3 — a checklist with no written outcome is a checklist nobody ran.

- [ ] **Step 4: The five manual checks still owed from M6**

These predate M8 and no milestone has closed them (handoff §13, §14.4). They need a human at a Mac and a human at an iPad, which is why they keep slipping; do them now rather than carrying them into M9.

1. macOS: drag an image file from Finder onto the canvas — it becomes a Texture Sample node with that image assigned.
2. macOS: drag a node from the palette onto the canvas — it lands where it was dropped.
3. iPad with a hardware keyboard: check 14 of the M6 list (the shortcut sweep).
4. iPad: two-finger pan and pinch-zoom on the canvas.
5. iPad: Slide Over at compact width — the inspector collapses and nothing is unreachable.

Any that cannot be run (no iPad to hand) is reported as **not run**, not as passed.

- [ ] **Step 5: Write handoff §15**

Append to `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md`:

- **§15.1 What shipped** — the two node kinds, the legality predicate, the three RealityKit follow-ups, with commit count and test count before/after.
- **§15.2 Rulings** — every `Ruling:` line from the SDD ledger, numbered, with what each would cost if wrong.
- **§15.3 In-app checklist results** — all thirteen lines above with their outcomes, plus the five M6 checks.
- **§15.4 Defects the reviews caught that the tests did not** — the M7 section of this shape was the most useful part of the handoff; keep it.
- **§15.5 M9 starting list** — what M8 deferred: the code editor's gutter decoration, a second open definition at once, `#include` of user files, and anything the checklist turned up.

- [ ] **Step 6: Update the memory files**

Rewrite `metalnodes-project-state.md` so it describes M8 as the current state rather than M7, keeping the RealityKit and Metal-validation gotchas that are still true and adding the ones M8 found. Update the `MEMORY.md` pointer line to match. Add any new plan-execution pitfalls to `metalnodes-plan-execution-lessons.md` rather than starting a third file.

- [ ] **Step 7: Commit**

```bash
git add docs MetalNodesKit
git commit -m "docs: M8 execution record — custom code, legality predicate, RealityKit follow-ups

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---
