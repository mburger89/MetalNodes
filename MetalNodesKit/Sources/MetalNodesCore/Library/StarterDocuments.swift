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

    /// The `-mnFixture textured` document (spec §22.8): UV → Texture Sample (no asset yet) →
    /// Fragment Output, the last wire left for the UI test to draw. Node ids are fixed so a test
    /// can address `node.<8hex>` and `socket.<8hex>.<name>`; they differ in their first eight hex
    /// digits because that is exactly the prefix `GroupCodegen.hex8` takes.
    static func textured() -> ShaderDocument {
        func id(_ s: String) -> NodeID { NodeID(raw: UUID(uuidString: s)!) }
        let uv = NodeInstance(id: id("00000101-0000-0000-0000-000000000000"),
                              kind: .builtin("input.uv"), position: CGPoint(x: 0, y: 0))
        let tex = NodeInstance(id: id("00000102-0000-0000-0000-000000000000"),
                               kind: .builtin("texture.sample"), position: CGPoint(x: 300, y: 0),
                               params: ["asset": .asset(nil)])
        let out = NodeInstance(id: id("00000103-0000-0000-0000-000000000000"),
                               kind: .builtin("output.fragment"), position: CGPoint(x: 620, y: 0))

        var g = Graph()
        for n in [uv, tex, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(uv.id, "uv"), to: SocketRef(tex.id, "uv"))

        var doc = ShaderDocument()
        doc.root = g
        return doc
    }
}
