import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct ShaderDocumentTests {
    /// `doc[path]` mutates the graph where it lives — the `_modify` accessor yields the
    /// definition's storage rather than handing back a copy to be written whole.
    @Test func subscriptMutatesTheDefinitionInPlace() {
        let def = GroupDefinition.make(name: "Fbm")
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let n = NodeInstance(kind: .builtin("input.float"))
        doc[.definition(def.id)].nodes[n.id] = n
        doc[.definition(def.id)].nodes[n.id]?.position = CGPoint(x: 5, y: 7)
        doc[.definition(def.id)].connect(SocketRef(n.id, "out"), to: SocketRef(def.outputNode!, "v"))
        #expect(doc.definitions[def.id]?.graph.nodes[n.id]?.position == CGPoint(x: 5, y: 7))
        #expect(doc.definitions[def.id]?.graph.inputs[SocketRef(def.outputNode!, "v")] == SocketRef(n.id, "out"))
        #expect(doc.definitions[def.id]?.graph.nodes.count == 3)
    }

    @Test func subscriptMutatesTheRootInPlace() {
        var doc = ShaderDocument()
        let n = NodeInstance(kind: .builtin("input.float"))
        doc[.root].nodes[n.id] = n
        doc[.root].nodes[n.id]?.customTitle = "Speed"
        #expect(doc.root.nodes[n.id]?.customTitle == "Speed")
    }

    /// Assigning a whole graph still works — the `set` accessor is what batched writes use.
    @Test func assigningAWholeGraphStillWorks() {
        let def = GroupDefinition.make(name: "Fbm")
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        var g = doc[.definition(def.id)]
        let n = NodeInstance(kind: .builtin("input.float"))
        g.nodes[n.id] = n
        doc[.definition(def.id)] = g
        #expect(doc.definitions[def.id]?.graph.nodes[n.id] != nil)
    }

    /// The XCUITest fixture (spec §22.8). Its ids are fixed *and distinct in their first eight hex
    /// digits*, because that prefix is what `GroupCodegen.hex8` — and every accessibility
    /// identifier built from it — uses. The Texture Sample's `color` output is deliberately
    /// unconnected: it is what the wire-drag UI test connects.
    @Test func texturedFixtureHasStableIdentifiers() {
        let doc = ShaderDocument.textured()
        let uv = NodeID(raw: UUID(uuidString: "00000101-0000-0000-0000-000000000000")!)
        let tex = NodeID(raw: UUID(uuidString: "00000102-0000-0000-0000-000000000000")!)
        let out = NodeID(raw: UUID(uuidString: "00000103-0000-0000-0000-000000000000")!)
        #expect(Set(doc.root.nodes.keys) == Set([uv, tex, out]))
        #expect(doc.root.nodes[tex]?.kind == .builtin("texture.sample"))
        #expect(doc.root.inputs[SocketRef(tex, "uv")] == SocketRef(uv, "uv"))
        #expect(doc.root.inputs[SocketRef(out, "color")] == nil)
        #expect(Set([uv, tex, out].map(GroupCodegen.hex8)) == Set(["00000101", "00000102", "00000103"]))
    }
}
