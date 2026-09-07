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
}
