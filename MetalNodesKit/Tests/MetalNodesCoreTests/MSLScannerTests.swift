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

    /// A stray `}` that only exists inside a comment must not appear to close a real, still-open
    /// brace — the comment's `}` does not count, so the true imbalance is still reported.
    @Test func anUnbalancedBraceInsideACommentIsNotReportedAsBalanced() {
        #expect(kinds("if (a) { b = 1; /* } */") == [.unbalancedBrace])
    }

    @Test func violationsCarryTheLine() {
        let v = MSLScanner.scopeBreakers(in: "out = a;\n#include <x>\n")
        #expect(v.count == 1)
        #expect(v[0].line == 1)
    }

    /// C/C++/MSL strip comments before recognising directives (translation phase 3, before phase
    /// 4) — so a directive sharing a line with a comment is still a real directive, and a directive
    /// that only exists inside a comment is not one at all. `scopeBreakers` must agree with the
    /// compiler on both directions, or a hidden `#include` reaches codegen unrefused.
    @Test func aPreprocessorDirectiveIsRecognisedAroundComments() {
        #expect(kinds("/* comment */ #include <metal_stdlib>\na") == [.preprocessor("include")])
        #expect(kinds("// #include <metal_stdlib>\na") == [])
        #expect(kinds("/* one\n#include <x>\nthree */\na") == [])
    }

    /// Blanking a comment must not shift any later line's number.
    @Test func commentBlankingPreservesLineNumbers() {
        let v = MSLScanner.scopeBreakers(in: "/* a\nb */\n\n\n#include <z>\n")
        #expect(v.count == 1)
        #expect(v[0].line == 4)
    }

    /// An unbraced loop body silently relocates whatever a caller inserts as the loop body's first
    /// statement (Task 8's runaway-loop guard) — refusing it, rather than trying to pin down where
    /// that guard would even land, keeps every other diagnostic (and `loopSites`) trustworthy.
    @Test func refusesAnUnbracedForBody() {
        #expect(kinds("for (int i = 0; i < 4; ++i) x += 1.0;") == [.unbracedLoopBody])
    }

    @Test func refusesAnUnbracedWhileBody() {
        #expect(kinds("while (x) y += 1.0;") == [.unbracedLoopBody])
    }

    @Test func refusesAnUnbracedDoBody() {
        #expect(kinds("do y += 1.0; while (a);") == [.unbracedLoopBody])
    }

    /// The pathological case that motivated the rule: an unbraced `do` whose single statement is
    /// itself a braced loop. Pairing which `while` closes which construct is ambiguous here (that
    /// is exactly the gap `loopOpeners` documents), so this only asserts that the text is refused
    /// at all — not which lines, and nothing about `loopSites`, which is meaningless once refused.
    @Test func refusesADoWhoseUnbracedBodyIsItselfALoop() {
        #expect(kinds("do while (x) { y += 1.0; } while (a);").contains(.unbracedLoopBody))
    }

    @Test func doesNotRefuseBracedLoopBodies() {
        #expect(kinds("for (int i = 0; i < n; i++) { s += i; }") == [])
        #expect(kinds("while (t > 0.0) { t -= 1.0; }") == [])
        #expect(kinds("do { t -= 1.0; } while (t > 0.0);") == [])
    }

    /// The brace is still there — a comment or a newline between the header and `{` must not read
    /// as a missing body. This is the false-refusal direction and it must not fire.
    @Test func aDelayedBraceIsNotMistakenForAMissingOne() {
        #expect(kinds("while (x) /* go */ { y += 1.0; }") == [])
        #expect(kinds("while (x)\n{\n  y += 1.0;\n}") == [])
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

    /// A `do`'s closing `while` must be paired with its own `do` by brace depth, not by simple
    /// order — otherwise a nested `do { do { } while(a); } while(b);` reports the outer closing
    /// `while` as a third, spurious site. Every reported site must genuinely open a loop body: a
    /// caller hardens each site by inserting a guard as the first statement of that body, and a
    /// guard inserted at a closing `while` either fails to compile or breaks the wrong loop.
    @Test func nestedDoWhileReportsExactlyTwoSites() {
        #expect(MSLScanner.loopSites(in: "do { do { s += 1.0; } while (a); } while (b);") == [0, 0])
    }

    /// Same nesting, spread across lines so each reported site can be checked against the line it
    /// names: both reported lines open a `do`, neither is a closing `while` line.
    @Test func nestedDoWhileSitesAreTheOpeningLinesNotTheClosingWhiles() {
        let s = """
        do {
          do {
            s += 1.0;
          } while (a);
        } while (b);
        """
        #expect(MSLScanner.loopSites(in: s) == [0, 1])
    }

    /// `loopSites`' guarantee that every reported site opens a braced body must hold on its own,
    /// not merely because a caller happens to have already run `scopeBreakers` and refused the
    /// text. An unbraced opener is filtered out here directly, whether or not it was ever refused.
    @Test func anUnbracedLoopReportsNoSite() {
        #expect(MSLScanner.loopSites(in: "while (x) y += 1.0;") == [])
        #expect(MSLScanner.loopSites(in: "for (int i = 0; i < 4; ++i) x += 1.0;") == [])
        #expect(MSLScanner.loopSites(in: "do y += 1.0; while (a);") == [])
    }

    /// A mix of one braced and one unbraced loop reports only the braced one, at its own line —
    /// the filter must not drop a real site alongside the one it correctly excludes.
    @Test func aMixOfBracedAndUnbracedLoopsReportsOnlyTheBracedSite() {
        let s = "while (x) y += 1.0;\nfor (int i = 0; i < 4; i++) { s += i; }"
        #expect(MSLScanner.loopSites(in: s) == [1])
    }
}
