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
}

/// All wires in one `Canvas`, drawn beneath the nodes.
struct WireLayer: View {
    let graph: Graph
    let anchors: [SocketRef: CGPoint]
    let color: (SocketRef) -> Color

    var body: some View {
        Canvas { ctx, _ in
            for (to, from) in graph.inputs {
                guard let a = anchors[from], let b = anchors[to] else { continue }
                ctx.stroke(WireGeometry.path(from: a, to: b), with: .color(color(from)), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}
