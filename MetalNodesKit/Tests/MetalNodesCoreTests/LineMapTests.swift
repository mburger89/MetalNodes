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
