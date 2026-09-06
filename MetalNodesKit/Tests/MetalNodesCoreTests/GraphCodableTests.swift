import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct GraphCodableTests {
    private func twoNodeGraph() -> (Graph, NodeID, NodeID) {
        let a = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 10, y: 20))
        let b = NodeInstance(kind: .builtin("output.fragment"), position: CGPoint(x: 300, y: 20),
                             params: ["gain": .float(2)])
        var g = Graph()
        g.nodes[a.id] = a
        g.nodes[b.id] = b
        g.connect(SocketRef(a.id, "uv"), to: SocketRef(b.id, "color"))
        return (g, a.id, b.id)
    }

    @Test func documentRoundTripsThroughJSON() throws {
        let (g, _, _) = twoNodeGraph()
        var doc = ShaderDocument()
        doc.root = g
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(ShaderDocument.self, from: data)
        #expect(back == doc)
        #expect(back.formatVersion == ShaderDocument.currentFormatVersion)
    }

    @Test func jsonUsesArraysNotFlattenedDictionaries() throws {
        let (g, _, _) = twoNodeGraph()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
        #expect((json["nodes"] as? [[String: Any]])?.count == 2)
        let edges = json["edges"] as? [[String: Any]]
        #expect(edges?.count == 1)
        #expect(edges?.first?["to"] != nil)
        #expect(edges?.first?["from"] != nil)
    }

    @Test func connectingASecondWireReplacesTheFirst() {
        var (g, a, b) = twoNodeGraph()
        let c = NodeInstance(kind: .builtin("input.time"))
        g.nodes[c.id] = c
        g.connect(SocketRef(c.id, "time"), to: SocketRef(b, "color"))
        #expect(g.source(feeding: SocketRef(b, "color")) == SocketRef(c.id, "time"))
        #expect(g.inputs.count == 1)
        _ = a
    }

    @Test func removingANodeRemovesItsWires() {
        var (g, a, b) = twoNodeGraph()
        g.remove(node: a)
        #expect(g.nodes[a] == nil)
        #expect(g.source(feeding: SocketRef(b, "color")) == nil)
        #expect(g.inputs.isEmpty)
    }

    @Test func upstreamNodesAreTransitive() {
        var (g, a, b) = twoNodeGraph()
        let mid = NodeInstance(kind: .builtin("math.math"))
        g.nodes[mid.id] = mid
        g.connect(SocketRef(a, "uv"), to: SocketRef(mid.id, "a"))
        g.connect(SocketRef(mid.id, "out"), to: SocketRef(b, "color"))
        #expect(g.upstreamNodes(of: b) == Set([a, mid.id]))
        #expect(g.upstreamNodes(of: a).isEmpty)
    }

    @Test func viewStateRoundTrips() throws {
        var vs = EditorViewState()
        vs.cameras[.root] = Camera(pan: CGSize(width: 5, height: -3), zoom: 1.5)
        vs.selection = [NodeID()]
        let data = try JSONEncoder().encode(vs)
        #expect(try JSONDecoder().decode(EditorViewState.self, from: data) == vs)
    }

    @Test func internalEdgesOnlyIncludeEdgesWithBothEndsInside() {
        var (g, a, b) = twoNodeGraph()
        let c = NodeInstance(kind: .builtin("input.time"))
        g.nodes[c.id] = c
        g.connect(SocketRef(c.id, "time"), to: SocketRef(b, "color"))   // replaces a→b
        g.connect(SocketRef(a, "uv"), to: SocketRef(c.id, "x"))         // a→c (nonsense socket, fine for the graph type)
        #expect(g.internalEdges(among: [a, c.id]) == [Edge(to: SocketRef(c.id, "x"), from: SocketRef(a, "uv"))])
        #expect(g.internalEdges(among: [b]).isEmpty)
        #expect(g.edgeList.count == 2)
    }

    @Test func removeNodesDropsAllTouchingWiresInOneCall() {
        var (g, a, b) = twoNodeGraph()
        let c = NodeInstance(kind: .builtin("math.math"))
        g.nodes[c.id] = c
        g.connect(SocketRef(a, "uv"), to: SocketRef(c.id, "a"))
        g.remove(nodes: [a, c.id])
        #expect(g.nodes.keys.sorted { $0.raw.uuidString < $1.raw.uuidString } == [b])
        #expect(g.inputs.isEmpty)
    }
}
