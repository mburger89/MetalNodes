import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct NodeGeometryTests {
    let reg = NodeRegistry.builtin

    @Test func estimatedSizeCountsRows() {
        let sep = reg["vector.separate"]!          // 1 input, 0 params, 3 outputs = 4 rows
        let s = NodeGeometry.estimatedSize(for: sep)
        #expect(s.width == 190)
        #expect(s.height == 130)   // header 26 + padding 16 + 4 rows × 22
    }

    @Test func frameStartsAtPosition() {
        let n = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 100, y: 50))
        let f = NodeGeometry.frame(for: n, def: reg["input.uv"]!)
        #expect(f.origin == CGPoint(x: 100, y: 50))
        #expect(f.width == 190)
    }

    @Test func marqueeHitsIntersectingNodesOnly() {
        let doc = ShaderDocument.sample()      // uv at (0,0), time at (0,160), speed at (0,280) …
        let hit = NodeGeometry.nodes(in: doc.root, intersecting: CGRect(x: -10, y: -10, width: 50, height: 50), registry: reg)
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        #expect(hit == [uv.id])
        #expect(NodeGeometry.nodes(in: doc.root, intersecting: CGRect(x: 5000, y: 5000, width: 1, height: 1), registry: reg).isEmpty)
    }

    @Test func boundsUnionAllFrames() {
        let doc = ShaderDocument.sample()
        let all = NodeGeometry.bounds(of: doc.root.nodes.keys, in: doc.root, registry: reg)!
        #expect(all.minX == 0 && all.minY == 0)
        #expect(all.maxX == 1290)   // out node at x 1100 + width 190
        #expect(NodeGeometry.bounds(of: [NodeID](), in: doc.root, registry: reg) == nil)
    }

    @Test func visibleNodesCullByViewportWithMargin() {
        let doc = ShaderDocument.sample()
        // Viewport 400×300 at zoom 1 looking at the origin: uv(0,0), time(0,160), speed(0,280), sep(220,0), mul(220,200) intersect
        // the 200 pt-expanded rect; out(1100,200) does not.
        let t = CanvasTransform(pan: .zero, zoom: 1)
        let vis = NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: CGSize(width: 400, height: 300), registry: reg, margin: 200)
        let ids = Set(vis.map(\.id))
        let out = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        #expect(ids.contains(uv.id))
        #expect(!ids.contains(out.id))
        #expect(vis.map(\.id.raw.uuidString) == vis.map(\.id.raw.uuidString).sorted())   // stable order
        let all = NodeGeometry.visibleNodes(in: doc.root, transform: CanvasTransform(pan: .zero, zoom: 0.15), viewport: CGSize(width: 400, height: 300), registry: reg, margin: 200)
        #expect(all.count == 11)                                                       // zoomed out, everything fits
    }
}
