import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct LoopHardeningTests {
    /// Compiles `hardened` (already the output of `LoopHardening.harden`) as the body of a
    /// minimal kernel, using the real `xcrun metal` toolchain — the only way to prove text is
    /// valid MSL rather than merely containing the right substrings. `a` and `s` are declared
    /// locals every fix-round-1 test body reads/writes; `int i`/`int j` come from the loop
    /// headers themselves. Skips silently (same pattern as `CustomMSLEmissionTests`) when the
    /// toolchain isn't installed.
    private func compiles(_ hardened: String) throws -> Bool {
        guard MetalCompiler.isAvailable else { return true }

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void mn_loop_hardening_test(device float *buf [[buffer(0)]]) {
            float a = buf[0];
            float s = 0.0;
        \(hardened)
            buf[0] = s;
        }
        """
        let r = try MetalCompiler.compile(source)
        if r.status != 0 {
            Issue.record("metal -c failed for hardened body:\n\(hardened)\n\n\(r.log)")
            return false
        }
        return true
    }

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

    /// The guard name appears at least twice: once where it's declared, once where it's checked
    /// and incremented. (Named `hardeningIsIdempotentInShape` in the original brief, which tested
    /// neither idempotence nor "shape" — fix round 1.)
    @Test func theGuardNameAppearsInBothTheDeclarationAndTheCheck() {
        let once = LoopHardening.harden("while (a) { b(); }")
        #expect(once.components(separatedBy: "mn_loopGuard0").count - 1 >= 2)  // declared and incremented
    }

    /// The counter check must land INSIDE the loop's braces — right after its opening `{` — not
    /// merely appended after the whole (one-line) loop statement. A `break` outside any loop is
    /// invalid MSL: it would fail to *compile*, not just fail to bound the loop. A naive per-line
    /// hardener that inserts the check as a whole new line after the loop's source line would put
    /// it after the closing `}` for a loop whose header and body share one physical line — which
    /// is the shape every other test in this suite (and the spec's own examples) actually use.
    @Test func theCheckLandsInsideTheLoopBeforeItsClosingBrace() {
        let out = LoopHardening.harden("for (int i = 0; i < 4; i++) { s += 1.0; }")
        let breakRange = out.range(of: "break")!
        let closeRange = out.range(of: "}", options: .backwards)!
        #expect(breakRange.lowerBound < closeRange.lowerBound)
    }

    /// Do-while's own check must land inside its body too — the same misplacement would put
    /// `break` after the trailing `while (…);`, which is not even inside a loop's braces there.
    @Test func theCheckLandsInsideADoWhilesBody() {
        let out = LoopHardening.harden("do { t -= 1.0; } while (t > 0.0);")
        let breakRange = out.range(of: "break")!
        let closeRange = out.range(of: "}", options: .backwards)!
        #expect(breakRange.lowerBound < closeRange.lowerBound)
    }

    /// `hardened(_:)` reports which user line each emitted line came from — `nil` for a line the
    /// hardener inserted. The next task maps compiler errors back to the user's own line numbers
    /// using this array, so an inserted line must never claim a user line, and a line that is a
    /// fragment of the user's own source must be attributed to it.
    @Test func hardenedReportsUserLineOriginsForEveryEmittedLine() {
        let (text, userLines) = LoopHardening.hardened("for (int i = 0; i < 4; i++) { s += 1.0; }")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == userLines.count)
        // At least one inserted line (the declaration or the check) and at least one line that
        // still traces back to the user's single source line (0).
        #expect(userLines.contains(nil))
        #expect(userLines.contains(0))
        #expect(userLines.allSatisfy { $0 == nil || $0 == 0 })
    }

    /// A body with no loop at all gains nothing: `hardened` is the identity, one user line per
    /// emitted line, with no `nil` entries.
    @Test func aBodyWithNoLoopGetsNoUserLineInsertions() {
        let (text, userLines) = LoopHardening.hardened("out = in_a * 2.0;")
        #expect(text == "out = in_a * 2.0;")
        #expect(userLines == [0])
    }

    /// A carried defect (Task 8, surfaced by Task 9): `Character("\r\n")` is one grapheme cluster,
    /// so splitting on `Character("\n")` alone would see a Windows-pasted body as a single line
    /// and report a `userLines` array with one (wrong) entry instead of one per physical line.
    /// `hardened` normalises line endings on the way in specifically to prevent this.
    @Test func aCRLFBodyStillReportsOneUserLinePerPhysicalLine() {
        let (text, userLines) = LoopHardening.hardened("float a = 1.0;\r\nfloat b = 2.0;\r\nout = a + b;")
        #expect(userLines == [0, 1, 2])
        #expect(text == "float a = 1.0;\nfloat b = 2.0;\nout = a + b;")
    }

    /// The same defect, but with a loop before the CRLF-separated line that errors — proving the
    /// normalisation and the hardening insertions compose correctly rather than one undoing the
    /// other's line count.
    @Test func aCRLFBodyWithAHardenedLoopStillMapsThePostLoopLine() {
        let (_, userLines) = LoopHardening.hardened("for (int i = 0; i < 4; i++) { }\r\nout = a + b;")
        // Line 1 (0-based) is the user's second physical line, wherever it lands among the
        // hardener's insertions.
        #expect(userLines.contains(1))
    }

    // MARK: - Fix round 1: a loop in an unbraced statement slot

    /// A loop as the single unbraced body of an `if` — legal MSL, accepted by
    /// `MSLScanner.scopeBreakers` and `CustomCodeValidation` today. Splicing the counter
    /// declaration directly before the loop keyword (as the pre-fix-round-1 version did) steals
    /// the `if`'s single-statement slot, which the *editor* never sees since the user's own text
    /// is untouched — the failure only shows up as a GPU compile error naming a symbol
    /// (`mn_loopGuard0`) the user never wrote. Hardening must wrap the whole loop statement in its
    /// own braces instead.
    @Test func aLoopAsAnIfsUnbracedBodyIsWrappedAndCompiles() throws {
        let body = "if (a > 0.0) for (int i = 0; i < 4; i++) { s += 1.0; }"
        let out = LoopHardening.harden(body)
        #expect(out.contains("mn_loopGuard0"))
        #expect(try compiles(out))
    }

    /// The `else` mirror of the test above — a loop as the unbraced body of an `else`.
    @Test func aLoopAsAnElsesUnbracedBodyIsWrappedAndCompiles() throws {
        let body = "if (a > 0.0) { s = 1.0; } else while (s > 0.0) { s -= 1.0; }"
        let out = LoopHardening.harden(body)
        #expect(out.contains("mn_loopGuard0"))
        #expect(try compiles(out))
    }

    /// A loop directly after a `case` label with no braces of its own. Wrapping isn't only about
    /// making the loop statement's *own* slot legal here — without a scope of its own, the
    /// declaration's initialization would be visible to (and jumpable-over from) `default:`,
    /// which MSL's C++-family grammar refuses outright ("cannot jump from switch statement to
    /// this case label").
    @Test func aLoopAfterACaseLabelIsWrappedAndCompiles() throws {
        let body = "switch (int(a)) { case 1: for (int i = 0; i < 4; i++) { s += 1.0; } break; default: break; }"
        let out = LoopHardening.harden(body)
        #expect(out.contains("mn_loopGuard0"))
        #expect(try compiles(out))
    }

    /// Nested loops where only the outer one sits in an unbraced slot: the outer needs wrapping
    /// (preceded by `if (a)`'s `)`), the inner does not (preceded by the outer's own `{`, which is
    /// already a real statement boundary). Both still get their own counter.
    @Test func onlyTheOuterLoopIsWrappedWhenNested() throws {
        let body = "if (a > 0.0) for (int i = 0; i < 4; i++) { for (int j = 0; j < 4; j++) { s += 1.0; } }"
        let out = LoopHardening.harden(body)
        #expect(out.contains("mn_loopGuard0"))
        #expect(out.contains("mn_loopGuard1"))
        #expect(try compiles(out))
    }

    /// `userLines` stays exact once wrapping adds two more inserted lines (the opening and
    /// closing brace): every added line must map to `nil`, and every fragment must still trace
    /// back to line 0 — the whole body is one physical line.
    @Test func userLinesStaysExactWhenWrappingBracesAreInserted() {
        let (text, userLines) = LoopHardening.hardened("if (a > 0.0) for (int i = 0; i < 4; i++) { s += 1.0; }")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == userLines.count)
        #expect(userLines.allSatisfy { $0 == nil || $0 == 0 })
        // The wrap adds a `{` and a `}` on top of the declaration and check — at least four
        // inserted lines in total.
        #expect(userLines.filter { $0 == nil }.count >= 4)
        #expect(userLines.contains(0))
    }

    /// Fix round 1's other defect: leading indentation of the line the loop opener sits on must
    /// survive hardening. The pre-fix version dropped it by treating the whitespace before the
    /// declaration cut as disposable, which flushed the loop's own line left.
    @Test func indentationOfTheLoopOpenerLineSurvives() {
        let out = LoopHardening.harden("for (int i = 0; i < 4; i++) {\n  for (int j = 0; j < 4; j++) {\n    s += 1.0;\n  }\n}")
        #expect(out.contains("\n  for (int j = 0; j < 4; j++) {"))
    }
}
