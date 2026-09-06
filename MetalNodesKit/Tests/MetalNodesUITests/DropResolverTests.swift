import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct DropResolverTests {
    let reg = NodeRegistry.builtin
    let doc = ShaderDocument.sample()
    func node(_ defID: String) -> NodeInstance { doc.root.nodes.values.first { $0.kind == .builtin(defID) }! }
    var resolved: [NodeID: ResolvedNode] { (try? ShaderGenerator.generate(doc))?.resolved ?? [:] }
    /// What the canvas passes for the root graph — `EditorModel.shape(of:)` with the active path
    /// at the root.
    var shapes: (NodeInstance) -> NodeShape? { { doc.shape(of: $0, in: .root, registry: reg) } }

    /// Anchors as if every input socket sat 20 pt right of its node's origin, one row per input.
    var anchors: [SocketRef: CGPoint] {
        var a: [SocketRef: CGPoint] = [:]
        for n in doc.root.nodes.values {
            guard case .builtin(let id) = n.kind, let def = reg[id] else { continue }
            for (i, d) in def.inputs.enumerated() {
                a[SocketRef(n.id, d.name)] = CGPoint(x: n.position.x, y: n.position.y + 30 + CGFloat(i) * 22)
            }
            for (i, d) in def.outputs.enumerated() {
                a[SocketRef(n.id, d.name)] = CGPoint(x: n.position.x + 190, y: n.position.y + 30 + CGFloat(i) * 22)
            }
        }
        return a
    }

    @Test func snapsToNearestCompatibleInputWithinRadius() {
        let uv = node("input.uv"), sep = node("vector.separate")
        let target = SocketRef(sep.id, "v")
        let p = CGPoint(x: anchors[target]!.x + 10, y: anchors[target]!.y - 8)   // ~12.8 pt away
        let r = DropResolver.resolve(point: p, source: SocketRef(uv.id, "uv"), dragType: .float2,
                                     anchors: anchors, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(r == .socket(target))
    }

    @Test func ignoresIncompatibleAndOutputSockets() {
        let uv = node("input.uv"), out = node("output.fragment")
        // Texture never converts; only `output.fragment.color` is nearby and it can't take a texture.
        let p = anchors[SocketRef(out.id, "color")]!
        let r = DropResolver.resolve(point: p, source: SocketRef(uv.id, "uv"), dragType: .texture,
                                     anchors: anchors, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(r == .node(out.id))          // falls through to the body rule
        let ownOutput = anchors[SocketRef(uv.id, "uv")]!
        let r2 = DropResolver.resolve(point: ownOutput, source: SocketRef(uv.id, "uv"), dragType: .float2,
                                      anchors: anchors, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(r2 == .empty)                // own node is excluded entirely
    }

    @Test func fallsBackToNodeBodyThenEmpty() {
        let uv = node("input.uv"), mix = node("math.mix")
        let inside = CGPoint(x: mix.position.x + 100, y: mix.position.y + 10)   // header, far from sockets
        let r = DropResolver.resolve(point: inside, source: SocketRef(uv.id, "uv"), dragType: .float2,
                                     anchors: anchors, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(r == .node(mix.id))
        let r2 = DropResolver.resolve(point: CGPoint(x: -500, y: -500), source: SocketRef(uv.id, "uv"), dragType: .float2,
                                      anchors: anchors, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(r2 == .empty)
    }

    @Test func firstCompatibleInputRespectsDeclarationOrder() {
        let mix = node("math.mix")
        let first = DropResolver.firstCompatibleInput(on: mix.id, for: .float, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(first == SocketRef(mix.id, "a"))
        let none = DropResolver.firstCompatibleInput(on: mix.id, for: .texture, graph: doc.root, shapes: shapes, resolved: resolved)
        #expect(none == nil)
    }

    /// Wiring must see a group instance's exposed sockets and a pseudo-node's mirrored ones,
    /// not just builtin definitions (spec §20.2).
    @Test func resolvesGroupInstanceAndPseudoSockets() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let wobble = try #require(doc.definitions.values.first)     // input "t": float, output "out": float
        let inst = try #require(doc.root.nodes.values.first { $0.kind == .group(wobble.id) })
        let root: (NodeInstance) -> NodeShape? = { doc.shape(of: $0, in: .root, registry: reg) }
        let first = DropResolver.firstCompatibleInput(on: inst.id, for: .float, graph: doc.root, shapes: root, resolved: [:])
        #expect(first == SocketRef(inst.id, "t"))
        #expect(DropResolver.outputType(of: SocketRef(inst.id, "out"), graph: doc.root, shapes: root, resolved: [:]) == .float)

        // Group Output's inputs are the definition's declared outputs.
        let inner: (NodeInstance) -> NodeShape? = { doc.shape(of: $0, in: .definition(wobble.id), registry: reg) }
        let go = try #require(wobble.outputNode)
        #expect(DropResolver.inputType(of: SocketRef(go, "out"), graph: wobble.graph, shapes: inner, resolved: [:]) == .float)
    }

    /// Spec §20.6: a pseudo-node's `+` takes any non-texture type, and a drag *from* `GroupInput.+`
    /// is a wildcard — it has no type yet, so any non-texture input takes it.
    @Test func plusSocketsTakeAnyNonTextureTypeAndWildcardDragsTakeAnyInput() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let wobble = try #require(doc.definitions.values.first)
        let inner: (NodeInstance) -> NodeShape? = { doc.shape(of: $0, in: .definition(wobble.id), registry: reg) }
        let go = try #require(wobble.outputNode)
        let mul = try #require(wobble.graph.nodes.values.first { $0.params["op"] == .enumCase("multiply") }).id
        let plus = SocketRef(go, NodeShape.plusSocketName)

        #expect(DropResolver.accepts(.float3, at: plus, graph: wobble.graph, shapes: inner, resolved: [:]))
        #expect(DropResolver.accepts(.texture, at: plus, graph: wobble.graph, shapes: inner, resolved: [:]) == false)
        #expect(DropResolver.accepts(.texture, at: SocketRef(go, "out"), graph: wobble.graph, shapes: inner, resolved: [:]) == false)
        // A body drop never picks the `+`: exposing is a deliberate drop on it. With the one
        // declared output gone, a Group Output has nothing left for a wire to land on.
        var bare = doc
        bare.definitions[wobble.id]!.outputs = []
        let bareShapes: (NodeInstance) -> NodeShape? = { bare.shape(of: $0, in: .definition(wobble.id), registry: reg) }
        #expect(bare.shape(of: go, registry: reg)?.inputs.map(\.name) == ["+"])
        #expect(DropResolver.firstCompatibleInput(on: go, for: .float, graph: wobble.graph, shapes: bareShapes, resolved: [:]) == nil)

        // A wildcard: every non-texture input, never the `+` itself.
        #expect(DropResolver.accepts(.float, at: SocketRef(mul, "b"), wildcard: true, graph: wobble.graph, shapes: inner, resolved: [:]))
        #expect(DropResolver.accepts(.float, at: plus, wildcard: true, graph: wobble.graph, shapes: inner, resolved: [:]) == false)
        #expect(DropResolver.firstCompatibleInput(on: mul, for: .float, wildcard: true, graph: wobble.graph,
                                                  shapes: inner, resolved: [:]) == SocketRef(mul, "a"))
    }

    /// The drop itself: a float3 dragged onto `Group Output.+` resolves to that socket, which is
    /// what `GraphCanvasView.endWire` turns into an exposed output.
    @Test func aDropOnThePlusSocketResolvesToIt() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let wobble = try #require(doc.definitions.values.first)
        let inner: (NodeInstance) -> NodeShape? = { doc.shape(of: $0, in: .definition(wobble.id), registry: reg) }
        let go = try #require(wobble.outputNode)
        let mul = try #require(wobble.graph.nodes.values.first { $0.params["op"] == .enumCase("multiply") }).id
        let plus = SocketRef(go, NodeShape.plusSocketName)
        // Group Output sits at (600, 0) and is 190 × 86, so a point well below it can only snap.
        let anchors = [plus: CGPoint(x: 600, y: 200)]
        let r = DropResolver.resolve(point: CGPoint(x: 600, y: 200), source: SocketRef(mul, "out"), dragType: .float3,
                                     anchors: anchors, graph: wobble.graph, shapes: inner, resolved: [:])
        #expect(r == .socket(plus))
    }

    @Test func socketNearPointPicksTheClosestAnchorWithinRadiusOnly() {
        let sep = node("vector.separate")
        let x = SocketRef(sep.id, "x"), y = SocketRef(sep.id, "y")
        let ax = anchors[x]!
        // 8 pt outboard of x, 22 pt rows: x is closest and inside a 10 pt radius; y is not.
        #expect(DropResolver.socket(near: CGPoint(x: ax.x + 8, y: ax.y), within: 10, anchors: anchors) == x)
        #expect(DropResolver.socket(near: CGPoint(x: ax.x, y: ax.y + 12), within: 10, anchors: anchors) == y)
        #expect(DropResolver.socket(near: CGPoint(x: ax.x + 11, y: ax.y), within: 10, anchors: anchors) == nil)
    }
}
