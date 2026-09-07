import Testing
@testable import MetalNodesCore

@Suite struct MaterialStagePartitionTests {
    /// A document with `input.float` → baseColor and `input.float3` → positionOffset.
    private func bothStages() -> (ShaderDocument, terminal: NodeID, colorNode: NodeID, offsetNode: NodeID) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let colorNode = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        let offsetNode = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, colorNode, offsetNode] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(colorNode.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offsetNode.id, "out")
        doc.root = g
        return (doc, terminal.id, colorNode.id, offsetNode.id)
    }

    @Test func eachStageSeesOnlyItsOwnUpstream() {
        let (doc, terminal, colorNode, offsetNode) = bothStages()
        let surface = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .surface)
        let geometry = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .geometry)
        #expect(surface.contains(colorNode))
        #expect(!surface.contains(offsetNode))
        #expect(geometry.contains(offsetNode))
        #expect(!geometry.contains(colorNode))
    }

    @Test func theTerminalIsLastInEveryStageOrder() {
        let (doc, terminal, _, _) = bothStages()
        for stage in MaterialStage.allCases {
            let order = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: stage)
            #expect(order.last == terminal, "\(stage)")
            #expect(order.filter { $0 == terminal }.count == 1, "\(stage)")
        }
    }

    @Test func anEmptyStageIsJustTheTerminal() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        doc.root = g
        #expect(MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry) == [terminal.id])
    }

    /// A node feeding both stages appears in both orders — it is computed once per stage,
    /// because the stages are different shader invocations that share no variables.
    @Test func aSharedNodeAppearsInBothOrders() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        let vec = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, time, vec] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(time.id, "time")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(vec.id, "out")
        doc.root = g
        let surface = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let geometry = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry)
        #expect(surface.contains(time.id))
        #expect(geometry.contains(vec.id))
    }
}

@Suite struct SharedBindingsTests {
    /// Both stages must emit against one `Uniforms` struct, because the preview binds one buffer
    /// to both the generated vertex function and the fragment function.
    @Test func bothStagesEmitAgainstOneLayout() {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var a = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        a.params["value"] = .float(0.25)
        var b = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        b.params["value"] = .float3(.init(1, 2, 3))
        for n in [terminal, a, b] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(a.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(b.id, "out")
        doc.root = g

        let surfaceOrder = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let geometryOrder = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry)
        func emit(_ order: [NodeID], shared: Emitter.SharedBindings?) -> Emitter.Output {
            let (resolved, diags) = TypeResolver.resolve(g, path: .root, document: doc, registry: .builtin, order: order)
            #expect(diags.isEmpty)
            return Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                resolved: resolved, env: .fragment, shared: shared)
        }
        let shared = MaterialCodegen.sharedBindings(surface: emit(surfaceOrder, shared: nil),
                                                   geometry: emit(geometryOrder, shared: nil))
        let s = emit(surfaceOrder, shared: shared)
        let gm = emit(geometryOrder, shared: shared)
        #expect(s.layout == gm.layout)
        #expect(s.layout == shared.layout)
        // Both slots live in the one struct even though neither stage alone requests both.
        let paths = Set(shared.layout.fields.compactMap(\.path))
        #expect(paths.contains(ParamPath(node: a.id, param: "value")))
        #expect(paths.contains(ParamPath(node: b.id, param: "value")))
    }

    @Test func sharedTextureSlotsKeepTheirIndices() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        for n in [terminal, sample] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(sample.id, "color")
        doc.root = g
        let order = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let (resolved, _) = TypeResolver.resolve(g, path: .root, document: doc, registry: .builtin, order: order)
        let first = Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                 resolved: resolved, env: .fragment)
        let shared = MaterialCodegen.sharedBindings(surface: first, geometry: first)
        let again = Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                 resolved: resolved, env: .fragment, shared: shared)
        #expect(again.textureRequests == shared.order)
        #expect(again.textureRequests.first?.index == 0)
    }
}
