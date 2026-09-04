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
}
