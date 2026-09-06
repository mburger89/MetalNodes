import Foundation
import CoreGraphics

public extension ShaderDocument {
    /// What File ▸ New opens (spec §21.1): the smallest graph that already renders — UV wired
    /// straight into the Fragment Output, so a new window shows a gradient rather than an error.
    static func starter() -> ShaderDocument {
        let uv = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 0, y: 0))
        let out = NodeInstance(kind: .builtin("output.fragment"), position: CGPoint(x: 300, y: 0))

        var g = Graph()
        g.nodes[uv.id] = uv
        g.nodes[out.id] = out
        g.connect(SocketRef(uv.id, "uv"), to: SocketRef(out.id, "color"))

        var doc = ShaderDocument()
        doc.root = g
        return doc
    }
}
