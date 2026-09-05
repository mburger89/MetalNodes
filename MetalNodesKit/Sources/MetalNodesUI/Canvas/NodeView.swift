import SwiftUI
import MetalNodesCore

struct NodeView: View {
    let node: NodeInstance
    let def: NodeDef
    let resolved: ResolvedNode?
    let graph: Graph
    let isSelected: Bool
    var compact = false
    let onChange: (DocumentChange) -> Void
    let onSelect: (SelectionMode) -> Void
    let onDragBegan: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onEditing: (Bool) -> Void
    var dragType: SocketType? = nil
    var onSocketDragBegan: (SocketRef, Bool) -> Void = { _, _ in }
    var onSocketDrag: (CGPoint) -> Void = { _ in }
    var onSocketDragEnded: (CGPoint) -> Void = { _ in }

    @State private var dragging = false
    @State private var wasSelectedAtStart = false
    @State private var socketDragging = false
    static let width: CGFloat = NodeGeometry.width

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(def.inputs, id: \.name) { inputRow($0) }
                    ForEach(def.params, id: \.name) { param in
                        ParamControl(label: param.label, kind: param.kind,
                                     value: node.params[param.name] ?? param.defaultValue,
                                     onChange: { onChange(.setParam(node.id, param.name, $0)) },
                                     onEditing: onEditing)
                    }
                    ForEach(def.outputs, id: \.name) { outputRow($0) }
                }
                .padding(8)
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 8).fill(DraculaToken.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? DraculaTheme.selection.color : DraculaToken.background.color, lineWidth: isSelected ? 2 : 1))
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 6, y: isSelected ? 0 : 3)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(InputModifiers.selectionMode()) }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if compact {
                VStack(spacing: 2) {
                    ForEach(def.inputs, id: \.name) { d in
                        SocketView(type: resolved?.inputTypes[d.name] ?? concrete(d.type), dimmed: dragType != nil)
                            .scaleEffect(0.6).socketAnchor(SocketRef(node.id, d.name)).frame(width: 6, height: 6)
                    }
                }
            }
            Text(node.customTitle ?? def.title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer()
            if compact {
                VStack(spacing: 2) {
                    ForEach(def.outputs, id: \.name) { d in
                        SocketView(type: resolved?.outputTypes[d.name] ?? concrete(d.type), dimmed: dragType != nil)
                            .scaleEffect(0.6).socketAnchor(SocketRef(node.id, d.name)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(DraculaToken.background.color)
        .background(DraculaTheme.token(for: def.category).color, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        wasSelectedAtStart = isSelected
                        let mode = InputModifiers.selectionMode()
                        // An already-selected node stays selected as-is (⌘-drag must not toggle it
                        // out of the selection before the drag snapshots origins); only an unselected
                        // node needs onSelect to establish/extend the selection before the drag starts.
                        if !isSelected { onSelect(mode) }
                        onDragBegan()
                    }
                    onDrag(g.translation)
                }
                .onEnded { g in
                    let wasDragging = dragging
                    dragging = false
                    if wasDragging { onDragEnded() }
                    if abs(g.translation.width) < 1 && abs(g.translation.height) < 1, wasSelectedAtStart {
                        let mode = InputModifiers.selectionMode()
                        // A click (no movement) on an already-selected node collapses the selection to it.
                        if mode == .replace {
                            onSelect(.replace)
                        } else if mode == .toggle {
                            // ⌘-drag moves the selection; ⌘-click (no movement) still toggles.
                            onSelect(.toggle)
                        }
                    }
                }
        )
    }

    private func inputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.inputTypes[decl.name] ?? concrete(decl.type)
        let wired = graph.inputs[ref] != nil
        let dim = dragType.map { !DropResolver.compatible($0, type) } ?? false
        return HStack(spacing: 6) {
            SocketView(type: type, dimmed: dim)
                .socketAnchor(ref)
                .offset(x: -8 - SocketView.size / 2)
                .gesture(socketDrag(ref, isInput: true))
            if !wired, case .value(let dflt) = decl.default {
                ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                             value: coerced(node.params[decl.name] ?? dflt, to: type),
                             onChange: { onChange(.setParam(node.id, decl.name, $0)) },
                             onEditing: onEditing)
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
            SocketView(type: type, dimmed: dragType != nil)
                .socketAnchor(ref)
                .offset(x: 8 + SocketView.size / 2)
                .gesture(socketDrag(ref, isInput: false))
        }
    }

    private func socketDrag(_ ref: SocketRef, isInput: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { g in
                if !socketDragging {
                    socketDragging = true
                    onSocketDragBegan(ref, isInput)
                }
                onSocketDrag(g.location)
            }
            .onEnded { g in
                socketDragging = false
                onSocketDragEnded(g.location)
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
