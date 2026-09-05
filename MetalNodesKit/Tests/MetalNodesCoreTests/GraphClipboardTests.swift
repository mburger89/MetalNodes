import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct GraphClipboardTests {
    /// a(10,20) → b(300,20), c(300,200) unconnected, plus an external node d fed by b.
    private func fixture() -> (Graph, a: NodeID, b: NodeID, c: NodeID, d: NodeID) {
        let a = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 10, y: 20))
        let b = NodeInstance(kind: .builtin("vector.separate"), position: CGPoint(x: 300, y: 20), params: ["k": .float(1)])
        let c = NodeInstance(kind: .builtin("input.time"), position: CGPoint(x: 300, y: 200))
        let d = NodeInstance(kind: .builtin("output.fragment"), position: CGPoint(x: 600, y: 20))
        var g = Graph()
        for n in [a, b, c, d] { g.nodes[n.id] = n }
        g.connect(SocketRef(a.id, "uv"), to: SocketRef(b.id, "v"))
        g.connect(SocketRef(b.id, "x"), to: SocketRef(d.id, "color"))
        return (g, a.id, b.id, c.id, d.id)
    }

    @Test func extractKeepsInternalEdgesAndRelativePositions() {
        let (g, a, b, c, _) = fixture()
        let clip = GraphClipboard.extract([a, b, c], from: g)
        #expect(clip.nodes.count == 3)
        #expect(clip.edges.count == 1)                              // a→b only; b→d is external
        #expect(clip.edges.first?.to.socket == "v")
        let positions = Dictionary(uniqueKeysWithValues: clip.nodes.map { ($0.id, $0.position) })
        #expect(positions[a] == CGPoint(x: 0, y: 0))
        #expect(positions[b] == CGPoint(x: 290, y: 0))
        #expect(positions[c] == CGPoint(x: 290, y: 180))
        #expect(clip.size == CGSize(width: 290, height: 180))
        #expect(clip.sourceOrigin == CGPoint(x: 10, y: 20))
        #expect(clip.formatVersion == GraphClipboard.currentFormatVersion)
        #expect(clip.nodes.first { $0.id == b }?.params["k"] == .float(1))
    }

    @Test func extractOfNothingIsEmpty() {
        let (g, _, _, _, _) = fixture()
        let clip = GraphClipboard.extract([], from: g)
        #expect(clip.nodes.isEmpty && clip.edges.isEmpty)
        #expect(clip.size == .zero)
    }

    @Test func materializeRemapsIDsAndOffsets() {
        let (g, a, b, _, _) = fixture()
        let clip = GraphClipboard.extract([a, b], from: g)
        let (nodes, edges) = clip.materialize(at: CGPoint(x: 1000, y: 500))
        #expect(nodes.count == 2 && edges.count == 1)
        let ids = Set(nodes.map(\.id))
        #expect(ids.isDisjoint(with: [a, b]))                       // fresh IDs
        #expect(ids.contains(edges[0].to.node) && ids.contains(edges[0].from.node))
        let byKind = Dictionary(uniqueKeysWithValues: nodes.map { ($0.kind, $0.position) })
        #expect(byKind[.builtin("input.uv")] == CGPoint(x: 1000, y: 500))
        #expect(byKind[.builtin("vector.separate")] == CGPoint(x: 1290, y: 500))
        let again = clip.materialize(at: .zero)
        #expect(Set(again.nodes.map(\.id)).isDisjoint(with: ids))    // every call is fresh
    }

    @Test func roundTripsThroughJSON() throws {
        let (g, a, b, c, _) = fixture()
        let clip = GraphClipboard.extract([a, b, c], from: g)
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(GraphClipboard.self, from: data) == clip)
    }

    @Test func decodingToleratesMissingOptionalKeys() throws {
        let json = #"{"nodes":[],"edges":[]}"#
        let clip = try JSONDecoder().decode(GraphClipboard.self, from: Data(json.utf8))
        #expect(clip.formatVersion == 1)
        #expect(clip.sourceOrigin == .zero)
        #expect(clip.stickies.isEmpty && clip.frames.isEmpty && clip.definitions.isEmpty)
    }
}
