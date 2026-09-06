import SwiftUI
import MetalNodesCore

struct NodeView: View {
    let node: NodeInstance
    let def: NodeDef
    let resolved: ResolvedNode?
    let graph: Graph
    let isSelected: Bool
    var compact = false
    var isViewed = false
    var hasError = false
    var onViewerToggle: () -> Void = {}
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
        Group {
            if def.style == .dot { dotBody } else { standardBody }
        }
    }

    /// The outline colour: an error wins over the selection, which wins over the plain border.
    /// The selection glow (the shadow) is unaffected, so an errored selected node still reads as
    /// selected (spec §19.5).
    private var outlineColor: Color {
        hasError ? DraculaTheme.error.color : (isSelected ? DraculaTheme.selection.color : DraculaToken.background.color)
    }

    private var outlineWidth: CGFloat { hasError || isSelected ? 2 : 1 }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(def.inputs, id: \.name) { inputRow($0) }
                    // Params marked `showsInBody == false` are inspector-only (spec §19.5).
                    ForEach(def.params.filter(\.showsInBody), id: \.name) { param in
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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(outlineColor, lineWidth: outlineWidth))
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 6, y: isSelected ? 0 : 3)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(InputModifiers.selectionMode()) }
    }

    /// The dot's two socket grabs are narrowed from the standard 20 pt: at that size they meet in
    /// the middle of the 24 pt body and leave only ~4 pt of it free to start a move.
    static let dotSocketHitSize: CGFloat = 8

    /// Reroute: a 24 × 24 dot in its resolved output type's colour, with the input anchored on the
    /// left edge and the output on the right. The `SocketView`s are invisible but present, so the
    /// anchors are still reported and socket drags still start from them exactly as on a standard
    /// node (spec §19.5).
    private var dotBody: some View {
        let type = resolved?.outputTypes[def.outputs.first?.name ?? ""] ?? .float
        return ZStack {
            Circle().fill(DraculaToken.surface.color)
            Circle().fill(DraculaTheme.token(for: type).color).padding(6)
            Circle().stroke(outlineColor, lineWidth: outlineWidth)
            if let i = def.inputs.first {
                let inType = resolved?.inputTypes[i.name] ?? concrete(i.type)
                SocketView(type: inType, dimmed: dragType.map { !DropResolver.compatible($0, inType) } ?? false, hitSize: Self.dotSocketHitSize)
                    .opacity(0.001)
                    .socketAnchor(SocketRef(node.id, i.name))
                    .gesture(socketDrag(SocketRef(node.id, i.name), isInput: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: -SocketView.size / 2)
            }
            if let o = def.outputs.first {
                SocketView(type: type, dimmed: dragType != nil, hitSize: Self.dotSocketHitSize)
                    .opacity(0.001)
                    .socketAnchor(SocketRef(node.id, o.name))
                    .gesture(socketDrag(SocketRef(node.id, o.name), isInput: false))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: SocketView.size / 2)
            }
        }
        .frame(width: NodeGeometry.dotSize, height: NodeGeometry.dotSize)
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 4, y: isSelected ? 0 : 2)
        .contentShape(Circle())
        .gesture(headerDrag)
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
            if hasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DraculaTheme.error.color)
                    .accessibilityLabel("Error")
            }
            Text(node.customTitle ?? def.title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer()
            // Nothing to view on an output-only node (spec §19.3): no badge.
            if !def.outputs.isEmpty {
                Image(systemName: isViewed ? "circle.circle.fill" : "circle.circle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isViewed ? DraculaTheme.viewerFlag.color : DraculaToken.background.color.opacity(0.55))
                    .padding(3)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { onViewerToggle() })
                    .accessibilityLabel(isViewed ? "Clear viewer" : "View this node")
            }
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
        .gesture(headerDrag)
    }

    /// Moving the node: on a standard node this lives on the header, on a `.dot` node the whole
    /// dot is the handle — the same gesture either way.
    private var headerDrag: some Gesture {
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
