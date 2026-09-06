import SwiftUI
import MetalNodesCore

struct NodeView: View {
    let node: NodeInstance
    let shape: NodeShape
    let resolved: ResolvedNode?
    let graph: Graph
    let isSelected: Bool
    var compact = false
    var isViewed = false
    var hasError = false
    var onViewerToggle: () -> Void = {}
    /// Double-click on the header: dives into a group instance, no-op for everything else (spec §20.8).
    var onOpen: () -> Void = {}
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
    /// Last header click, for synthesising the double-click that dives in: `headerDrag` claims
    /// single clicks with `minimumDistance: 0`, so a `TapGesture(count: 2)` never fires (M2 lesson).
    @State private var lastHeaderClick: (time: Date, point: CGPoint)?
    static let width: CGFloat = NodeGeometry.width

    var body: some View {
        Group {
            if shape.style == .dot { dotBody } else { standardBody }
        }
    }

    /// The outline colour: an error wins over the selection, which wins over a group instance's
    /// accent ring, which wins over the plain border.
    /// The selection glow (the shadow) is unaffected, so an errored selected node still reads as
    /// selected (spec §19.5).
    private var outlineColor: Color {
        if hasError { return DraculaTheme.error.color }
        if isSelected { return DraculaTheme.selection.color }
        return isGroupInstance ? accentColor : DraculaToken.background.color
    }

    private var outlineWidth: CGFloat { hasError || isSelected || isGroupInstance ? 2 : 1 }

    /// The definition's accent, falling back to the category's token (spec §20.2).
    private var accentColor: Color {
        shape.accent.map { DraculaTheme.token(for: $0).color } ?? DraculaTheme.token(for: shape.category).color
    }

    /// A group instance — not a pseudo-node, which is part of a definition rather than a call of one.
    private var isGroupInstance: Bool { shape.category == .group && !shape.isPseudo }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shape.inputs, id: \.name) { inputRow($0) }
                    // Params marked `showsInBody == false` are inspector-only (spec §19.5).
                    // A pseudo-node has none of its own — it only mirrors its definition's sockets.
                    if !shape.isPseudo {
                        ForEach(shape.params.filter(\.showsInBody), id: \.name) { param in
                            ParamControl(label: param.label, kind: param.kind,
                                         value: node.params[param.name] ?? param.defaultValue,
                                         onChange: { onChange(.setParam(node.id, param.name, $0)) },
                                         onEditing: onEditing)
                        }
                    }
                    ForEach(shape.outputs, id: \.name) { outputRow($0) }
                }
                .padding(8)
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 8).fill(DraculaToken.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(outlineColor, lineWidth: outlineWidth))
        // Doubled border: a group instance reads as "this is a function" (spec §12, §20.2). The
        // outer ring is the outline above — accent normally, and the selection/error colour when
        // one of those applies, so selection stays legible — and this is the inner one.
        .overlay { if isGroupInstance { innerAccentRing } }
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 6, y: isSelected ? 0 : 3)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(InputModifiers.selectionMode()) }
    }

    /// The inner ring of a group instance's doubled border, masked to the body: the header is
    /// filled with the same accent, so a ring drawn across it would be invisible anyway — and the
    /// header's own accent band is what doubles the border up there (spec §20.2). A compact node
    /// is all header, so nothing of the ring shows, which is what LOD wants.
    private var innerAccentRing: some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(accentColor, lineWidth: 1)
            .padding(3)
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: NodeGeometry.headerHeight)
                    Rectangle()
                }
            }
    }

    /// The dot's two socket grabs are narrowed from the standard 20 pt: at that size they meet in
    /// the middle of the 24 pt body and leave only ~4 pt of it free to start a move.
    static let dotSocketHitSize: CGFloat = 8

    /// Reroute: a 24 × 24 dot in its resolved output type's colour, with the input anchored on the
    /// left edge and the output on the right. The `SocketView`s are invisible but present, so the
    /// anchors are still reported and socket drags still start from them exactly as on a standard
    /// node (spec §19.5).
    private var dotBody: some View {
        let type = resolved?.outputTypes[shape.outputs.first?.name ?? ""] ?? .float
        return ZStack {
            Circle().fill(DraculaToken.surface.color)
            Circle().fill(DraculaTheme.token(for: type).color).padding(6)
            Circle().stroke(outlineColor, lineWidth: outlineWidth)
            if let i = shape.inputs.first {
                let inType = resolved?.inputTypes[i.name] ?? concrete(i.type)
                SocketView(type: inType, dimmed: dragType.map { !DropResolver.compatible($0, inType) } ?? false, hitSize: Self.dotSocketHitSize)
                    .opacity(0.001)
                    .socketAnchor(SocketRef(node.id, i.name))
                    .gesture(socketDrag(SocketRef(node.id, i.name), isInput: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: -SocketView.size / 2)
            }
            if let o = shape.outputs.first {
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
                    ForEach(shape.inputs, id: \.name) { d in
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
            Text(node.customTitle ?? shape.title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer()
            // Nothing to view on an output-only node (spec §19.3), nor on a pseudo-node, whose
            // outputs are the enclosing definition's inputs (spec §20.8): no badge.
            if !shape.outputs.isEmpty && !shape.isPseudo {
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
                    ForEach(shape.outputs, id: \.name) { d in
                        SocketView(type: resolved?.outputTypes[d.name] ?? concrete(d.type), dimmed: dragType != nil)
                            .scaleEffect(0.6).socketAnchor(SocketRef(node.id, d.name)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(DraculaToken.background.color)
        .background(accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
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
                guard abs(g.translation.width) < 1 && abs(g.translation.height) < 1 else {
                    lastHeaderClick = nil
                    return
                }
                // Read once, before anything branches on it: a modified click is a selection
                // gesture, so it may neither complete a double-click nor arm one — two quick
                // ⌘-clicks stay two toggles.
                let mode = InputModifiers.selectionMode()
                if mode == .replace {
                    // Second click of a double-click: open, and do nothing else — the selection
                    // must not collapse underneath the dive (the move it also started was a no-op,
                    // so its transaction registers nothing).
                    if let last = lastHeaderClick, Date.now.timeIntervalSince(last.time) < 0.4,
                       hypot(g.location.x - last.point.x, g.location.y - last.point.y) <= 4 {
                        lastHeaderClick = nil
                        onOpen()
                        return
                    }
                    lastHeaderClick = (time: .now, point: g.location)
                } else {
                    lastHeaderClick = nil
                }
                if wasSelectedAtStart {
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
            // A pseudo-node carries no params of its own: its rows mirror the definition's
            // sockets, so an unwired one stays a plain label (spec §20.8).
            if !wired, !shape.isPseudo, case .value(let dflt) = decl.default {
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
