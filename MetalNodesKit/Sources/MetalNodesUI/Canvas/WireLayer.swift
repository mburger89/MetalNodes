import SwiftUI
import MetalNodesCore

enum WireGeometry {
    /// Horizontal handle length: half the horizontal distance, never less than 40 (spec §11.1).
    static func controlOffset(from a: CGPoint, to b: CGPoint) -> CGFloat {
        max(40, abs(b.x - a.x) * 0.5)
    }

    static func path(from a: CGPoint, to b: CGPoint) -> Path {
        let d = controlOffset(from: a, to: b)
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + d, y: a.y), control2: CGPoint(x: b.x - d, y: b.y))
        return p
    }

    /// Point on the cubic at parameter `t`, using the same control points as `path`.
    static func point(t: CGFloat, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let d = controlOffset(from: a, to: b)
        let c1 = CGPoint(x: a.x + d, y: a.y), c2 = CGPoint(x: b.x - d, y: b.y)
        let u = 1 - t
        let x = u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x
        let y = u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y
        return CGPoint(x: x, y: y)
    }

    /// Distance from `p` to the wire, sampled at 24 points (spec §18.5).
    static func distance(from p: CGPoint, wireFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for i in 0...24 {
            let q = point(t: CGFloat(i) / 24, from: a, to: b)
            best = min(best, hypot(q.x - p.x, q.y - p.y))
        }
        return best
    }
}

/// All wires in one `Canvas`, drawn beneath the nodes. The selected wire is drawn last, thicker, in `foreground`.
struct WireLayer: View {
    let graph: Graph
    let anchors: [SocketRef: CGPoint]
    let shapes: (NodeInstance) -> NodeShape?
    var selected: SocketRef? = nil
    var pending: PendingWire? = nil
    let color: (SocketRef) -> Color

    /// Measured where the socket is on screen, computed where it is not: a culled node reports no
    /// anchor, and a wire with one endpoint off screen must still be drawn (spec §18.9).
    private func anchor(_ ref: SocketRef) -> CGPoint? {
        anchors[ref] ?? NodeGeometry.socketAnchor(for: ref, in: graph, shapes: shapes)
    }

    var body: some View {
        Canvas { ctx, _ in
            for (to, from) in graph.inputs where to != selected {
                guard let a = anchor(from), let b = anchor(to) else { continue }
                ctx.stroke(WireGeometry.path(from: a, to: b), with: .color(color(from)), lineWidth: 2)
            }
            if let to = selected, let from = graph.inputs[to], let a = anchor(from), let b = anchor(to) {
                ctx.stroke(WireGeometry.path(from: a, to: b), with: .color(DraculaTheme.selection.color), lineWidth: 3.5)
            }
            if let p = pending, let a = anchor(p.source) {
                ctx.stroke(WireGeometry.path(from: a, to: p.point),
                           with: .color(DraculaTheme.token(for: p.type).color.opacity(0.85)), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}
