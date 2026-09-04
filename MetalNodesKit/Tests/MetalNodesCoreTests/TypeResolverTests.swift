import Testing
@testable import MetalNodesCore

@Suite struct TypeResolverTests {
    let reg = NodeRegistry.builtin

    private func resolve(_ g: Graph) -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        let t = GraphValidator.terminal(in: g)!
        return TypeResolver.resolve(g, registry: reg, order: TopoSort.order(g, from: t))
    }

    private func graph(with builder: (inout Graph, NodeID) -> Void) -> Graph {
        var g = Graph()
        let out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[out.id] = out
        builder(&g, out.id)
        return g
    }

    @Test func unconnectedGenericDefaultsToFloat() {
        var mathID = NodeID()
        let g = graph { g, out in
            let m = NodeInstance(kind: .builtin("math.math")); mathID = m.id
            g.nodes[m.id] = m
            g.connect(SocketRef(m.id, "out"), to: SocketRef(out, "color"))
        }
        let r = resolve(g)
        #expect(r.nodes[mathID]?.generics["T"] == .float)
        #expect(r.nodes[mathID]?.outputTypes["out"] == .float)
        #expect(r.diagnostics.isEmpty)
    }

    @Test func genericWidensToLargestConnectedInput() {
        var mixID = NodeID()
        let g = graph { g, out in
            let comb = NodeInstance(kind: .builtin("vector.combine"))
            let f = NodeInstance(kind: .builtin("input.float"))
            let mix = NodeInstance(kind: .builtin("math.mix")); mixID = mix.id
            for n in [comb, f, mix] { g.nodes[n.id] = n }
            g.connect(SocketRef(f.id, "out"), to: SocketRef(mix.id, "a"))      // float
            g.connect(SocketRef(comb.id, "out"), to: SocketRef(mix.id, "b"))   // float3
            g.connect(SocketRef(mix.id, "out"), to: SocketRef(out, "color"))
        }
        let r = resolve(g)
        #expect(r.nodes[mixID]?.generics["T"] == .float3)
        #expect(r.nodes[mixID]?.inputTypes["a"] == .float3)
        #expect(r.nodes[mixID]?.inputTypes["t"] == .float)
    }

    @Test func colorFeedingGenericResolvesToFloat4() {
        var mixID = NodeID()
        let g = graph { g, out in
            let c = NodeInstance(kind: .builtin("input.color"))
            let mix = NodeInstance(kind: .builtin("math.mix")); mixID = mix.id
            g.nodes[c.id] = c; g.nodes[mix.id] = mix
            g.connect(SocketRef(c.id, "out"), to: SocketRef(mix.id, "a"))
            g.connect(SocketRef(mix.id, "out"), to: SocketRef(out, "color"))
        }
        #expect(resolve(g).nodes[mixID]?.generics["T"] == .float4)
    }

    @Test func genericPicksSmallestAllowedThatFits() {
        var lenID = NodeID()
        let g = graph { g, out in
            let f = NodeInstance(kind: .builtin("input.float"))
            let len = NodeInstance(kind: .builtin("vector.length")); lenID = len.id
            g.nodes[f.id] = f; g.nodes[len.id] = len
            g.connect(SocketRef(f.id, "out"), to: SocketRef(len.id, "v"))   // float into {float2,float3,float4}
            g.connect(SocketRef(len.id, "out"), to: SocketRef(out, "color"))
        }
        #expect(resolve(g).nodes[lenID]?.generics["T"] == .float2)
    }

    @Test func sampleDocumentResolvesCleanly() {
        let r = resolve(ShaderDocument.sample().root)
        #expect(r.diagnostics.isEmpty)
        #expect(r.nodes.count == 11)
    }

    @Test func concreteSocketsKeepTheirTypes() {
        var sepID = NodeID()
        let g = graph { g, out in
            let sep = NodeInstance(kind: .builtin("vector.separate")); sepID = sep.id
            g.nodes[sep.id] = sep
            g.connect(SocketRef(sep.id, "x"), to: SocketRef(out, "color"))
        }
        let r = resolve(g)
        #expect(r.nodes[sepID]?.inputTypes["v"] == .float3)
        #expect(r.nodes[sepID]?.outputTypes["x"] == .float)
    }
}
