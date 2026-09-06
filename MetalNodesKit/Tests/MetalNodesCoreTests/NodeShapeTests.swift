import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct NodeShapeTests {
    let reg = NodeRegistry.builtin

    private func docWithGroup() -> (ShaderDocument, GroupID, NodeID) {
        var def = GroupDefinition.make(name: "Fbm")
        def.inputs = [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                      SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)))]
        def.outputs = [SocketDecl(name: "value", type: .concrete(.float))]
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), position: CGPoint(x: 10, y: 20))
        doc.root.nodes[inst.id] = inst
        return (doc, def.id, inst.id)
    }

    @Test func builtinShapeMirrorsItsDefinition() throws {
        let def = try #require(reg["math.math"])
        let s = NodeShape(def: def)
        #expect(s.title == "Math" && s.category == .math && s.accent == nil)
        #expect(s.inputs.map(\.name) == ["a", "b"] && s.outputs.map(\.name) == ["out"])
        #expect(s.params.map(\.name) == ["op"] && s.generics["T"] != nil && s.style == .standard && !s.isPseudo)
    }

    @Test func instanceShapeComesFromTheDefinition() {
        let (doc, gid, iid) = docWithGroup()
        let s = doc.shape(of: iid, registry: reg)!
        #expect(s.title == "Fbm" && s.category == .group && s.accent == .purple)
        #expect(s.inputs.map(\.name) == ["uv", "scale"] && s.outputs.map(\.name) == ["value"])
        #expect(s.params.isEmpty && s.generics.isEmpty && !s.isPseudo)
        #expect(doc.node(iid)?.path == .root)
        #expect(doc.definitions[gid]?.name == "Fbm")
    }

    /// Each pseudo-node also carries the trailing `+` socket sockets are added by wiring into
    /// (spec §20.6): an output on `GroupInput`, an input on `GroupOutput`.
    @Test func pseudoNodeShapesMirrorTheEnclosingDefinitionAndEndInAPlusSocket() {
        let (doc, gid, _) = docWithGroup()
        let def = doc.definitions[gid]!
        let inShape = doc.shape(of: def.inputNode!, registry: reg)!
        let outShape = doc.shape(of: def.outputNode!, registry: reg)!
        #expect(inShape.title == "Group Input" && inShape.inputs.isEmpty && inShape.outputs.map(\.name) == ["uv", "scale", "+"] && inShape.isPseudo)
        #expect(outShape.title == "Group Output" && outShape.outputs.isEmpty && outShape.inputs.map(\.name) == ["value", "+"] && outShape.isPseudo)
        #expect(doc.node(def.inputNode!)?.path == .definition(gid))
        let plus = outShape.inputs.last!
        #expect(NodeShape.isPlus(plus) && plus.type == TypeRef.concrete(.float) && plus.default == SocketDefault.required)
        #expect(NodeShape.isPlus(inShape.outputs.first!) == false)
    }

    /// Only a pseudo-node grows one: a group instance's sockets are exactly its definition's.
    @Test func instancesAndBuiltinsHaveNoPlusSocket() throws {
        let (doc, _, iid) = docWithGroup()
        let s = doc.shape(of: iid, registry: reg)!
        #expect(s.inputs.contains { NodeShape.isPlus($0) } == false)
        #expect(s.outputs.contains { NodeShape.isPlus($0) } == false)
        let math = try #require(reg["math.math"])
        #expect(NodeShape(def: math).inputs.contains { NodeShape.isPlus($0) } == false)
    }

    @Test func makeCreatesBothPseudoNodesAndSubscriptMutatesTheRightGraph() {
        var doc = ShaderDocument()
        let def = GroupDefinition.make(name: "G")
        #expect(def.inputNode != nil && def.outputNode != nil && def.graph.nodes.count == 2)
        #expect(def.graph.nodes[def.inputNode!]?.position == CGPoint(x: 0, y: 0))
        doc.definitions[def.id] = def
        let n = NodeInstance(kind: .builtin("input.float"))
        doc[.definition(def.id)].nodes[n.id] = n
        #expect(doc.graph(at: .definition(def.id))?.nodes.count == 3)
        #expect(doc.root.nodes.isEmpty)
        #expect(doc.graph(at: .definition(GroupID())) == nil)
    }

    @Test func contentHashChangesWithNameSocketsOrGraph() {
        var a = GroupDefinition.make(name: "A")
        let h0 = a.contentHash
        #expect(h0 == a.contentHash)                      // deterministic
        a.name = "B"; let h1 = a.contentHash
        a.inputs.append(SocketDecl(name: "x", type: .concrete(.float))); let h2 = a.contentHash
        let n = NodeInstance(kind: .builtin("input.float")); a.graph.nodes[n.id] = n; let h3 = a.contentHash
        #expect(Set([h0, h1, h2, h3]).count == 4)
        #expect(h0.count == 16)
    }

    @Test func activePathPrefersTheStackThenTheEditedDefinition() {
        let (doc, gid, iid) = docWithGroup()
        var v = EditorViewState()
        #expect(v.activePath(in: doc) == .root)
        v.editingDefinition = gid
        #expect(v.activePath(in: doc) == .definition(gid))
        v.editingStack = [iid]
        #expect(v.activePath(in: doc) == .definition(gid))
        v.editingStack = [NodeID()]                       // a dangling instance falls back
        v.editingDefinition = nil
        #expect(v.activePath(in: doc) == .root)
    }

    @Test func viewStateDecodesWithoutTheNewKey() throws {
        let legacy = #"{"editingStack":[],"selection":[],"cameras":[]}"#
        let v = try JSONDecoder().decode(EditorViewState.self, from: Data(legacy.utf8))
        #expect(v.editingDefinition == nil)
    }

    /// A `view.json` written before M5 has no comment selection and no panel flags (spec §21.4–§21.6).
    @Test func viewStateDecodesWithoutTheM5Keys() throws {
        let legacy = #"{"editingStack":[],"selection":[],"cameras":[]}"#
        let v = try JSONDecoder().decode(EditorViewState.self, from: Data(legacy.utf8))
        #expect(v.selectedComments.isEmpty)
        #expect(v.showsCode == false)
        #expect(v.showsMinimap == true)
    }

    @Test func viewStateRoundTripsTheM5Keys() throws {
        var v = EditorViewState()
        v.selectedComments = [.sticky(StickyID()), .frame(FrameID())]
        v.showsCode = true
        v.showsMinimap = false
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(EditorViewState.self, from: data) == v)
    }
}
