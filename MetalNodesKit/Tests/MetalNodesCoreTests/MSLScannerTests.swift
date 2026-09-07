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
