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
        // Viewport 400×300 at zoom 1 looking at the origin: uv(0,0), time(0,160), speed(0,280), sep(220,0), mul(220,200),
        // sine(440,200), noise(440,360) intersect the 200 pt-expanded rect (x < 600, y < 500);
        // comb(660,60), tint(660,360), mixN(880,200), out(1100,200) do not.
        let t = CanvasTransform(pan: .zero, zoom: 1)
        let vis = NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: CGSize(width: 400, height: 300), registry: reg, margin: 200)
        let ids = Set(vis.map(\.id))
        let out = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        let sine = doc.root.nodes.values.first { $0.kind == .builtin("math.math") && $0.params["op"] == .enumCase("sine") }!
        #expect(ids.contains(uv.id))
        #expect(!ids.contains(out.id))
        // sine sits at x 440..630: outside the raw 400-wide viewport, but inside the 200 pt-expanded one —
        // this exercises the margin itself, not just the base viewport intersection.
        #expect(ids.contains(sine.id))
        let noMargin = NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: CGSize(width: 400, height: 300), registry: reg, margin: 0)
        #expect(!Set(noMargin.map(\.id)).contains(sine.id))
        #expect(vis.map(\.id.raw.uuidString) == vis.map(\.id.raw.uuidString).sorted())   // stable order
        let all = NodeGeometry.visibleNodes(in: doc.root, transform: CanvasTransform(pan: .zero, zoom: 0.15), viewport: CGSize(width: 400, height: 300), registry: reg, margin: 200)
        #expect(all.count == 11)                                                       // zoomed out, everything fits
    }

    /// Synthesised anchors stand in for sockets that were never rendered (a culled node), so they
    /// must land where `NodeView` would have put them. Derived from its layout constants: the
    /// body starts below the 26 pt header, is inset by 8 pt, and stacks one 22 pt row per input,
    /// then per param, then per output, each row's 16 pt of content centred in its pitch — so row
    /// *i* is centred at 26 + 8 + 22·i + 8. `NodeView.inputRow` offsets its socket by
    /// `-8 - SocketView.size / 2` from the padded row edge, which puts the dot exactly on the
    /// node's left edge; `outputRow` mirrors that onto the right edge.
    @Test func synthesizedSocketAnchorsMatchNodeViewLayout() {
        let doc = ShaderDocument.sample()
        // Separate XYZ at (220, 0): input "v" is row 0, outputs x/y/z are rows 1…3 (no params).
        let sep = doc.root.nodes.values.first { $0.kind == .builtin("vector.separate") }!
        #expect(NodeGeometry.socketAnchor(for: SocketRef(sep.id, "v"), in: doc.root, registry: reg) == CGPoint(x: 220, y: 42))
        #expect(NodeGeometry.socketAnchor(for: SocketRef(sep.id, "y"), in: doc.root, registry: reg) == CGPoint(x: 410, y: 86))
        // Math at (220, 200): inputs a/b are rows 0…1, the "op" param is row 2, output "out" is row 3.
        let mul = doc.root.nodes.values.first { $0.kind == .builtin("math.math") && $0.params["op"] == .enumCase("multiply") }!
        #expect(NodeGeometry.socketAnchor(for: SocketRef(mul.id, "b"), in: doc.root, registry: reg) == CGPoint(x: 220, y: 264))
        #expect(NodeGeometry.socketAnchor(for: SocketRef(mul.id, "out"), in: doc.root, registry: reg) == CGPoint(x: 410, y: 308))
        #expect(NodeGeometry.socketAnchor(for: SocketRef(sep.id, "nope"), in: doc.root, registry: reg) == nil)
        #expect(NodeGeometry.socketAnchor(for: SocketRef(NodeID(), "v"), in: doc.root, registry: reg) == nil)
    }

    /// A node dragged past the cull margin must keep rendering: its `NodeView` owns the drag
    /// gesture, so tearing it down cancels the gesture without `onEnded` and strands the open
    /// transaction (the canvas passes the in-flight node ids as `keeping`).
    @Test func visibleNodesKeepInFlightNodesAlive() {
        let doc = ShaderDocument.sample()
        let t = CanvasTransform(pan: .zero, zoom: 1)
        let vp = CGSize(width: 400, height: 300)
        let out = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!   // culled at this viewport
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!           // already visible
        let plain = NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: vp, registry: reg, margin: 200)
        let kept = NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: vp, registry: reg, margin: 200,
                                             keeping: [out.id, uv.id])
        #expect(kept.map(\.id).contains(out.id))
        #expect(kept.count == plain.count + 1)                                             // uv is not duplicated
        #expect(kept.map(\.id.raw.uuidString) == kept.map(\.id.raw.uuidString).sorted())   // still stable z-order
        #expect(NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: vp, registry: reg, margin: 200,
                                          keeping: [NodeID()]).count == plain.count)       // unknown id is ignored
    }
}
