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

    /// The hardest hardening case: a loop as the single unbraced body of an `if`, which wraps the
    /// whole statement in its own `{ … }` on top of the ordinary counter-declaration/check
    /// insertions — nine emitted program lines from three user lines (verified directly against
    /// `LoopHardening.hardened` before writing this). Every line the hardener inserted must map to
    /// `nil`, and every fragment of the wrapped loop's own line must still resolve to *that* line —
    /// not the line before or after it, which a naive flat-offset implementation would report.
    @Test func aWrappingBraceLoopMapsEveryLineExactly() throws {
        var doc = document()
        let gid = doc.definitions.keys.first!
        doc.definitions[gid]!.body = .msl(
            "float a = 1.0;\nif (a > 0.0) for (int i = 0; i < 4; i++) { a += 1.0; }\nout = nonexistent_fn(a);")
        let shader = try ShaderGenerator.generate(doc)
        let lines = shader.source.split(separator: "\n", omittingEmptySubsequences: false)
        func programLine(containing text: String) throws -> Int {
            try #require(lines.firstIndex { $0.contains(text) }) + 1
        }
        // Inserted scaffolding: the counter declaration and the check-and-break. (The wrapping `{`
        // and `}` are bare punctuation and not usefully greppable on their own — the declaration
        // and check already prove every inserted line is excluded.)
        #expect(shader.lineMap.userLine(forLine: try programLine(containing: "int mn_loopGuard0 = 0;")) == nil)
        #expect(shader.lineMap.userLine(forLine: try programLine(containing: "if (++mn_loopGuard0")) == nil)
        // The loop header is a fragment of the user's own second line, wherever hardening put it.
        #expect(shader.lineMap.userLine(forLine: try programLine(containing: "for (int i = 0; i < 4; i++)")) == 2)
        // The line after the wrapped loop is unaffected by the nine-line expansion before it.
        #expect(shader.lineMap.userLine(forLine: try programLine(containing: "nonexistent_fn")) == 3)
    }

    /// The Expression call site, closed in fix round 1: before this, `userEntries.count == 0` for
    /// any document whose only user text was an Expression's own formula — the mapping was not
    /// partial, it was entirely absent. `12345.0` is a literal, so it survives substitution
    /// unchanged and pins the line unambiguously.
    @Test func anExpressionNodesFormulaLineResolvesThroughUserLine() throws {
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("a * 12345.0"), "type": .enumCase("color")])
        g.nodes[t.id] = t; g.nodes[expr.id] = expr
        g.inputs[SocketRef(t.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        let shader = try ShaderGenerator.generate(doc)
        let lines = shader.source.split(separator: "\n", omittingEmptySubsequences: false)
        let programLine = try #require(lines.firstIndex { $0.contains("12345.0") }) + 1
        #expect(shader.lineMap.userLine(forLine: programLine) == 1)
    }

    /// The Expression call site again, this time reached through `MaterialCodegen`/
    /// `MaterialPreviewCodegen`'s own `bodyLines` consumption (the surface stage feeding a
    /// RealityKit material's Emissive input) rather than `ShaderGenerator.fragmentProgram`'s — a
    /// different call site entirely, so the 2D coverage above does not exercise it.
    @Test func anExpressionInsideAMaterialGraphResolvesThroughUserLine() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.material"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("a * 54321.0"), "type": .enumCase("color")])
        g.nodes[terminal.id] = terminal; g.nodes[expr.id] = expr
        g.inputs[SocketRef(terminal.id, "emissive")] = SocketRef(expr.id, "out")
        doc.root = g
        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let lines = shader.source.split(separator: "\n", omittingEmptySubsequences: false)
        let programLine = try #require(lines.firstIndex { $0.contains("54321.0") }) + 1
        #expect(shader.lineMap.userLine(forLine: programLine) == 1)
    }
}
