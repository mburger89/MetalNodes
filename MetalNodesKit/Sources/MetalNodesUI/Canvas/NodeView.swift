import SwiftUI
import MetalNodesCore

struct NodeView: View {
    let node: NodeInstance
    let def: NodeDef
    let resolved: ResolvedNode?
    let graph: Graph
    let onChange: (DocumentChange) -> Void

    @State private var dragOrigin: CGPoint?
    static let width: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 6) {
                ForEach(def.inputs, id: \.name) { inputRow($0) }
                ForEach(def.params, id: \.name) { param in
                    ParamControl(label: param.label, kind: param.kind,
                                 value: node.params[param.name] ?? param.defaultValue) {
                        onChange(.setParam(node.id, param.name, $0))
                    }
                }
                ForEach(def.outputs, id: \.name) { outputRow($0) }
            }
            .padding(8)
        }
        .frame(width: Self.width)
        .background(DraculaToken.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DraculaToken.background.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }

    private var header: some View {
        HStack {
            Text(node.customTitle ?? def.title).font(.caption.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(DraculaToken.background.color)
        .background(DraculaTheme.token(for: def.category).color)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if dragOrigin == nil { dragOrigin = node.position }
                    let o = dragOrigin!
                    onChange(.moveNode(node.id, to: CGPoint(x: o.x + g.translation.width, y: o.y + g.translation.height)))
                }
                .onEnded { _ in dragOrigin = nil }
        )
    }

    private func inputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.inputTypes[decl.name] ?? concrete(decl.type)
        let wired = graph.inputs[ref] != nil
        return HStack(spacing: 6) {
            SocketView(type: type).socketAnchor(ref).offset(x: -8 - SocketView.size / 2)
            if !wired, case .value(let dflt) = decl.default {
                ParamControl(label: decl.label, kind: .value(type, range: nil), value: coerced(node.params[decl.name] ?? dflt, to: type)) {
                    onChange(.setParam(node.id, decl.name, $0))
                }
            } else {
                Text(decl.label).font(.caption)
            }
        }
    }

    private func outputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.outputTypes[decl.name] ?? concrete(decl.type)
        return HStack(spacing: 6) {
            Spacer()
            Text(decl.label).font(.caption)
            SocketView(type: type).socketAnchor(ref).offset(x: 8 + SocketView.size / 2)
        }
    }

    private func concrete(_ t: TypeRef) -> SocketType {
        if case .concrete(let c) = t { return c } else { return .float }
    }

    /// Show a stored scalar as the resolved vector type so the control matches the socket.
    private func coerced(_ v: ParamValue, to type: SocketType) -> ParamValue {
        switch (v, type) {
        case (.float(let x), .float2): .float2(.init(x, x))
        case (.float(let x), .float3): .float3(.init(x, x, x))
        case (.float(let x), .float4), (.float(let x), .color): .float4(.init(x, x, x, 1))
        default: v
        }
    }
}
