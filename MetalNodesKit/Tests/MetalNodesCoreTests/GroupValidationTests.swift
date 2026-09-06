import Testing
import CoreGraphics
@testable import MetalNodesCore

@Suite struct GroupValidationTests {
    let reg = NodeRegistry.builtin

    /// Root: Float → Fbm-like group (uv, scale → value) → Output. Definition: GroupInput.scale → Math(add) → GroupOutput.value.
    static func fixture() -> (ShaderDocument, GroupID, NodeID) {
        var def = GroupDefinition.make(name: "Twice")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        def.graph.nodes[math.id] = math
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(math.id, "a"))
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(math.id, "b"))
        def.graph.connect(SocketRef(math.id, "out"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let f = NodeInstance(kind: .builtin("input.float"), params: ["value": .float(0.25)])
        let inst = NodeInstance(kind: .group(def.id))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [f, inst, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(inst.id, "x"))
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        return (doc, def.id, inst.id)
    }

    @Test func aWellFormedGroupDocumentValidates() {
        let (doc, _, _) = Self.fixture()
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).isEmpty)
    }

    @Test func definitionsNeedExactlyOnePseudoNodeOfEachKind() {
        var (doc, gid, _) = Self.fixture()
        let extra = NodeInstance(kind: .groupOutput)
        doc.definitions[gid]!.graph.nodes[extra.id] = extra
        let d = GraphValidator.validate(document: doc, registry: reg, target: .fragment)
        #expect(d.contains { $0.message == "A definition may have only one Group Output" && $0.node == extra.id })
        doc.definitions[gid]!.graph.nodes[extra.id] = nil
        doc.definitions[gid]!.graph.nodes[doc.definitions[gid]!.inputNode!] = nil
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "Definition “Twice” has no Group Input" })
    }

    @Test func pseudoNodesAreRefusedInTheRoot() {
        var (doc, _, _) = Self.fixture()
        let stray = NodeInstance(kind: .groupInput)
        doc.root.nodes[stray.id] = stray
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "Group Input is only valid inside a definition" && $0.node == stray.id })
    }

    @Test func danglingInstanceAndRecursionAreDiagnosed() {
        var (doc, gid, inst) = Self.fixture()
        doc.root.nodes[inst]!.kind = .group(GroupID())
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "Group definition is missing" && $0.node == inst })
        let (doc2, gid2, _) = Self.fixture()
        var d2 = doc2
        let selfInst = NodeInstance(kind: .group(gid2))
        d2.definitions[gid2]!.graph.nodes[selfInst.id] = selfInst
        #expect(GraphValidator.validate(document: d2, registry: reg, target: .fragment).contains { $0.message == "Definition “Twice” contains itself" })
        _ = gid
    }

    @Test func wiresIntoAnInstanceAreCheckedAgainstItsShape() {
        var (doc, _, inst) = Self.fixture()
        let f = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(inst, "nope"))
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "No input socket named “nope” on Twice" })
    }

    @Test func typesResolveThroughGroupsAndPseudoNodes() {
        let (doc, gid, inst) = Self.fixture()
        let rootOrder = TopoSort.order(doc.root, from: GraphValidator.terminal(in: doc.root)!)
        let (root, d1) = TypeResolver.resolve(doc.root, path: .root, document: doc, registry: reg, order: rootOrder)
        #expect(d1.isEmpty && root[inst]?.inputTypes["x"] == .float && root[inst]?.outputTypes["out"] == .float)
        let def = doc.definitions[gid]!
        let order = TopoSort.order(def.graph, from: def.outputNode!)
        let (inner, d2) = TypeResolver.resolve(def.graph, path: .definition(gid), document: doc, registry: reg, order: order)
        #expect(d2.isEmpty && inner[def.inputNode!]?.outputTypes["x"] == .float && inner[def.outputNode!]?.inputTypes["out"] == .float)
        let math = def.graph.nodes.values.first { $0.kind == .builtin("math.math") }!
        #expect(inner[math.id]?.outputTypes["out"] == .float)
    }

    @Test func viewerValidityWorksInAnyGraph() {
        let (doc, gid, _) = Self.fixture()
        let def = doc.definitions[gid]!
        let math = def.graph.nodes.values.first { $0.kind == .builtin("math.math") }!
        #expect(GraphValidator.isValidViewer(SocketRef(math.id, "out"), in: doc, registry: reg))
        #expect(!GraphValidator.isValidViewer(SocketRef(def.outputNode!, "out"), in: doc, registry: reg))   // pseudo-node has no outputs
        #expect(GraphValidator.isValidViewer(SocketRef(def.inputNode!, "x"), in: doc, registry: reg))
    }
}
