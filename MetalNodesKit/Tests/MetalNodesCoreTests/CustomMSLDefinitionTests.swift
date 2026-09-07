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
    ///
    /// (An `EntityID` encodes as a bare UUID string, not as `{"raw": …}` — `Identifiers.swift` —
    /// and a `Graph` writes `nodes`/`edges` as arrays — `Graph.swift`.)
    @Test func aLegacyDefinitionWithOnlyAGraphKeyStillDecodes() throws {
        let json = Data("""
        {"id":"E63408AB-F398-45E3-A306-E8B989C079CC","name":"Legacy","inputs":[],"outputs":[],
         "graph":{"nodes":[],"edges":[]},"accent":"purple"}
        """.utf8)
        let d = try JSONDecoder().decode(GroupDefinition.self, from: json)
        #expect(d.name == "Legacy")
        if case .graph = d.body {} else { Issue.record("legacy graph did not become a .graph body") }
    }

    /// A legacy definition's nodes and wires survive the migration, not just its `.graph` case.
    @Test func aLegacyDefinitionKeepsItsNodes() throws {
        var legacy = GroupDefinition.make(name: "Legacy")
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        legacy.graph.nodes[n.id] = n
        legacy.graph.connect(SocketRef(n.id, "out"), to: SocketRef(legacy.outputNode!, "out"))

        // Exactly what an M0–M7 build wrote: the same keys, with `graph` in place of `body`.
        var object: [String: Any] = [
            "id": legacy.id.raw.uuidString,
            "name": legacy.name,
            "inputs": [],
            "outputs": [],
            "accent": legacy.accent.rawValue,
        ]
        let graphJSON = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(legacy.graph))
        object["graph"] = graphJSON
        let data = try JSONSerialization.data(withJSONObject: object)

        let back = try JSONDecoder().decode(GroupDefinition.self, from: data)
        #expect(back == legacy)
        #expect(back.graph.nodes.count == 3)
        #expect(back.graph.inputs.count == 1)
    }

    /// A body kind a future build writes and this one has no case for must not fail the whole
    /// definition — and so the whole document (the same degradation §23.2 chose for `target`).
    @Test func anUnknownBodyKindDegradesInsteadOfFailingTheDocument() throws {
        let json = Data("""
        {"id":"E63408AB-F398-45E3-A306-E8B989C079CC","name":"Future","inputs":[],"outputs":[],
         "body":{"kind":"spirv","spirv":"…"},"accent":"purple"}
        """.utf8)
        let d = try JSONDecoder().decode(GroupDefinition.self, from: json)
        #expect(d.name == "Future")
        if case .graph(let g) = d.body { #expect(g.nodes.isEmpty) } else { Issue.record("unknown kind did not degrade to a graph body") }
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

    /// Writing a graph into a text definition is a category error, and the user's code is the
    /// thing that would be lost — so the write is dropped and the body keeps its kind.
    @Test func writingTheGraphConvenienceLeavesAnMSLBodyAlone() {
        var d = GroupDefinition(name: "W")
        d.body = .msl("out = 1.0;")
        var g = Graph()
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        g.nodes[n.id] = n
        d.graph = g
        d.graph.nodes[NodeID()] = n                       // the in-place path, too
        guard case .msl(let text) = d.body else { Issue.record("body stopped being msl"); return }
        #expect(text == "out = 1.0;")
    }

    /// `document[.definition(id)] = g` is the editor's mutation channel for a graph. Against a
    /// `.msl` body it must leave the code alone rather than convert the definition.
    @Test func writingThroughTheDocumentSubscriptLeavesAnMSLBodyAlone() {
        var doc = ShaderDocument()
        var d = GroupDefinition(name: "W")
        d.body = .msl("out = 1.0;")
        doc.definitions[d.id] = d

        var g = Graph()
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        g.nodes[n.id] = n
        doc[.definition(d.id)] = g                        // the setter
        doc[.definition(d.id)].nodes[n.id] = n            // the `_modify` path

        guard case .msl(let text) = doc.definitions[d.id]?.body else { Issue.record("body stopped being msl"); return }
        #expect(text == "out = 1.0;")
        #expect(doc[.definition(d.id)].nodes.isEmpty)
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
        let def = try #require(out.definitions[id])
        guard case .msl(let b) = def.body else { Issue.record("body stopped being msl"); return }
        #expect(b == "out = a * 2.0;")
    }

    @Test func makeUniqueCopiesTheText() throws {
        let (doc, id, inst) = document()
        let out = try #require(GroupOperations.makeUnique(inst, in: .root, of: doc))
        #expect(out.definition != id)
        let copy = try #require(out.document.definitions[out.definition])
        guard case .msl(let b) = copy.body else { Issue.record("copy is not an msl body"); return }
        #expect(b == "out = a * 2.0;")
        // The original is untouched — that is what "unique" means.
        let original = try #require(out.document.definitions[id])
        guard case .msl(let orig) = original.body else { Issue.record("original changed shape"); return }
        #expect(orig == "out = a * 2.0;")
    }

    /// `deleteDefinition` refuses while the definition is still instantiated and removes it once
    /// it is not (spec §20.6) — the same for a text body as for a graph one. (The brief's version
    /// of this test expected the delete to cascade through the instance; it never has.)
    @Test func deletingIsRefusedWhileUsedAndRemovesTheDefinitionOnceItIsNot() throws {
        var (doc, id, inst) = document()
        #expect(GroupOperations.isUsed(id, in: doc))
        #expect(GroupOperations.deleteDefinition(id, in: doc) == nil)

        doc.root.remove(node: inst)
        let out = try #require(GroupOperations.deleteDefinition(id, in: doc))
        #expect(out.definitions[id] == nil)
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
        let def = try #require(out.definitions[id])
        guard case .msl(let b) = def.body else { Issue.record("body stopped being msl"); return }
        #expect(b == "out = a * 2.0;")
    }

    /// A rename still rewires every *instance* of the definition, whatever the body is made of.
    @Test func renamingASocketStillRewiresInstances() throws {
        var (doc, id, inst) = document()
        let src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        doc.root.nodes[src.id] = src
        doc.root.connect(SocketRef(src.id, "out"), to: SocketRef(inst, "a"))
        let out = try #require(GroupOperations.renameSocket(id, kind: .input, from: "a", to: "amount", in: doc))
        #expect(out.root.inputs[SocketRef(inst, "amount")] == SocketRef(src.id, "out"))
        #expect(out.root.inputs[SocketRef(inst, "a")] == nil)
    }

    @Test func addingAndRemovingASocketLeavesTheBodyAlone() throws {
        let (doc, id, _) = document()
        let added = try #require(GroupOperations.addSocket(id, kind: .input, decl:
            SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(0))), in: doc))
        #expect(added.definitions[id]?.inputs.map(\.name) == ["a", "b"])
        let removed = try #require(GroupOperations.removeSocket(id, kind: .input, name: "b", in: added))
        #expect(removed.definitions[id]?.inputs.map(\.name) == ["a"])
        let def = try #require(removed.definitions[id])
        guard case .msl(let b) = def.body else { Issue.record("body stopped being msl"); return }
        #expect(b == "out = a * 2.0;")
    }

    @Test func setAccentKeepsTheBody() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.setAccent(id, .green, in: doc))
        #expect(out.definitions[id]?.accent == .green)
        let def = try #require(out.definitions[id])
        guard case .msl = def.body else { Issue.record("body stopped being msl"); return }
    }

    /// A `.msl` definition has no subgraph, so the pseudo-node rules ("has no Group Input") must
    /// not be applied to it — an empty graph is not what a text body is. What its *text* must
    /// satisfy is Task 7's question.
    @Test func aCodeDefinitionIsNotValidatedAsAnEmptyGraph() {
        var (doc, _, _) = document()
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        doc.root.nodes[terminal.id] = terminal
        let errors = GraphValidator.validate(document: doc, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.message))")
    }
}
