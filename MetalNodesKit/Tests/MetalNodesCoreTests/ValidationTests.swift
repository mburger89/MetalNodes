import Testing
@testable import MetalNodesCore

@Suite struct ValidationTests {
    let reg = NodeRegistry.builtin

    private func errors(_ g: Graph, target: OutputTarget = .fragment) -> [String] {
        GraphValidator.validate(g, registry: reg, target: target).filter { $0.severity == .error }.map(\.message)
    }

    @Test func sampleDocumentIsValid() {
        #expect(errors(ShaderDocument.sample().root).isEmpty)
    }

    @Test func missingOutputNode() {
        var g = Graph()
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("input.uv"))
        #expect(errors(g).contains { $0.contains("Fragment Output") })
    }

    @Test func twoOutputNodesFlagsTheExtra() {
        var g = Graph()
        let a = NodeInstance(kind: .builtin("output.fragment")), b = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[a.id] = a; g.nodes[b.id] = b
        let d = GraphValidator.validate(g, registry: reg, target: .fragment)
        #expect(d.filter { $0.message.contains("only one") }.count == 1)
    }

    @Test func unknownDefinition() {
        var g = Graph()
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("nope.nope"))
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("output.fragment"))
        #expect(errors(g).contains { $0.contains("nope.nope") })
    }

    @Test func groupsAreNotYetSupported() {
        var g = Graph()
        g.nodes[NodeID()] = NodeInstance(kind: .group(GroupID()))
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("output.fragment"))
        #expect(errors(g).contains { $0.contains("group") })
    }

    @Test func danglingWireEndpoints() {
        var g = Graph()
        let out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[out.id] = out
        g.connect(SocketRef(NodeID(), "uv"), to: SocketRef(out.id, "color"))
        #expect(errors(g).contains { $0.contains("missing node") })
        g.inputs = [:]
        let uv = NodeInstance(kind: .builtin("input.uv")); g.nodes[uv.id] = uv
        g.connect(SocketRef(uv.id, "zzz"), to: SocketRef(out.id, "color"))
        #expect(errors(g).contains { $0.contains("zzz") })
    }

    @Test func cyclesAreReported() {
        var g = Graph()
        let a = NodeInstance(kind: .builtin("math.math")), b = NodeInstance(kind: .builtin("math.math"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [a, b, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(a.id, "out"), to: SocketRef(b.id, "a"))
        g.connect(SocketRef(b.id, "out"), to: SocketRef(a.id, "a"))
        g.connect(SocketRef(b.id, "out"), to: SocketRef(out.id, "color"))
        let d = GraphValidator.validate(g, registry: reg, target: .fragment)
        #expect(d.contains { $0.message.contains("cycle") && $0.node != nil })
    }

    @Test func requiredInputsMustBeWired() throws {
        let def = NodeDef(id: "t.req", title: "Req", category: .math,
                          inputs: [SocketDecl(name: "x", type: .concrete(.float), default: .required)],
                          outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                          body: .template("{out.out} = {in.x};"))
        let r = try NodeRegistry(BuiltinNodes.all + [def])
        var g = Graph()
        let n = NodeInstance(kind: .builtin("t.req")), out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[n.id] = n; g.nodes[out.id] = out
        g.connect(SocketRef(n.id, "out"), to: SocketRef(out.id, "color"))
        let d = GraphValidator.validate(g, registry: r, target: .fragment)
        #expect(d.contains { $0.node == n.id && $0.socket == "x" })
    }

    @Test func stitchableTargetIsRejectedUntilM3() {
        #expect(errors(ShaderDocument.sample().root, target: .stitchable(.colorEffect)).contains { $0.contains("not yet supported") })
    }

    @Test func unknownEnumCaseIsRejected() {
        var g = Graph()
        let m = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("bogus")])
        let out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[m.id] = m; g.nodes[out.id] = out
        g.connect(SocketRef(m.id, "out"), to: SocketRef(out.id, "color"))
        let d = GraphValidator.validate(g, registry: reg, target: .fragment)
        #expect(d.contains { $0.severity == .error && $0.node == m.id && $0.socket == "op" })
    }
}
